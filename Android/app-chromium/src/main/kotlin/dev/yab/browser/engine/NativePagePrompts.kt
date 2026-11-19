package dev.yab.browser.engine

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.text.InputFilter
import android.text.InputType
import android.view.View
import android.widget.ArrayAdapter
import android.widget.DatePicker
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.NumberPicker
import android.widget.ScrollView
import android.widget.TextView
import android.widget.TimePicker
import com.cefrium.CefriumBrowser
import com.cefrium.CefriumBrowser.PermissionCallback
import com.cefrium.CefriumChromeClient
import com.cefrium.CefriumDateTimeInputType
import com.cefrium.CefriumFileChooserCallback
import com.cefrium.CefriumFileChooserParams
import com.cefrium.CefriumPickerHandler
import dev.yab.browser.model.WebFormValues
import dev.yab.browser.model.WebFormValues.Kind
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.YearMonth
import java.time.ZoneOffset
import java.time.temporal.IsoFields
import java.util.Locale

/**
 * Native answers stay bound to the initiating browser and document. Cefrium splits
 * prompt kinds across several handlers, so one instance registers itself on every
 * browser and routes each handler to the same single-dialog lifecycle as the
 * Gecko edition: one visible prompt at a time, ownership-checked before show.
 */
class NativePagePrompts(
    private val activity: Activity,
    private val owns: (CefriumBrowser) -> Boolean,
    private val canPresent: () -> Boolean = { true },
    private val requestFiles: (Array<String>, (List<Uri>) -> Unit) -> Unit,
) {
    private var dialog: AlertDialog? = null
    private val mutablePending = kotlinx.coroutines.flow.MutableStateFlow(false)
    val pending: kotlinx.coroutines.flow.StateFlow<Boolean> = mutablePending
    private var cancel: (() -> Unit)? = null
        set(value) { field = value; mutablePending.value = value != null }
    private var activeSession: CefriumBrowser? = null
    private val handler = Handler(Looper.getMainLooper())
    private var externalFilePrompt = false
    private var pickerTimeout: Runnable? = null

    fun hasPending(session: CefriumBrowser): Boolean = activeSession === session && cancel != null
    val awaitingFile: Boolean get() = externalFilePrompt && cancel != null

    fun dismissForBackground() {
        if (!externalFilePrompt || cancel == null) dismiss()
    }

    private fun clearPickerLease() {
        pickerTimeout?.let(handler::removeCallbacks)
        pickerTimeout = null
        externalFilePrompt = false
    }

    fun dismiss() {
        val callback = cancel
        cancel = null
        activeSession = null
        clearPickerLease()
        val previous = dialog
        dialog = null
        try { dismissAttached(previous) } finally { callback?.invoke() }
    }

    private fun dismissAttached(previous: AlertDialog?) {
        // Activity destruction may already have removed this owned window. Still
        // resolve the revoked prompt once, without asking WindowManager to remove it twice.
        if (previous?.window?.decorView?.isAttachedToWindow == true) previous.dismiss()
    }

    fun register(browser: CefriumBrowser) {
        browser.setJsDialogHandler(object : CefriumBrowser.JsDialogHandler {
            override fun onJsDialog(type: Int, title: String, message: String, callback: CefriumBrowser.JsDialogCallback): Boolean {
                jsDialog(browser, type, title, message, callback)
                return true
            }
            override fun onBeforeUnloadDialog(message: String, isReload: Boolean, callback: CefriumBrowser.JsDialogCallback): Boolean {
                val respond: (Boolean) -> Unit = { leave -> callback.continueDialog(leave, null) }
                if (!present(browser, { respond(false) }) { builder, done ->
                    builder.setTitle("Leave this page?").setMessage("Changes you made may not be saved.")
                        .setPositiveButton("Leave") { _, _ -> done(); respond(true) }
                        .setNegativeButton("Stay") { _, _ -> done(); respond(false) }
                }) respond(false)
                return true
            }
        })
        browser.setPickerHandler(object : CefriumPickerHandler {
            override fun onShowSelect(items: Array<CefriumPickerHandler.SelectItem>, defaultIndex: Int, multiple: Boolean, callback: CefriumPickerHandler.SelectCallback): Boolean {
                selectDialog(browser, items, defaultIndex, multiple, callback); return true
            }
            override fun onShowDateTime(type: CefriumDateTimeInputType, dialogValue: Double, min: Double, max: Double, step: Double, callback: CefriumPickerHandler.DateTimeCallback): Boolean {
                dateTimeDialog(browser, type, dialogValue, min, max, callback); return true
            }
            override fun onShowColor(defaultColor: Int, presets: IntArray?, callback: CefriumPickerHandler.ColorCallback): Boolean {
                colorDialog(browser, defaultColor, presets, callback); return true
            }
        })
        browser.setPermissionHandler(object : CefriumBrowser.PermissionHandler {
            override fun onPermissionRequest(origin: String, permission: Int, callback: PermissionCallback) {
                val name = when (permission) {
                    CefriumBrowser.PERMISSION_GEOLOCATION -> "your location"
                    CefriumBrowser.PERMISSION_CAMERA -> "your camera"
                    CefriumBrowser.PERMISSION_MICROPHONE -> "your microphone"
                    CefriumBrowser.PERMISSION_NOTIFICATIONS -> "notifications"
                    CefriumBrowser.PERMISSION_CLIPBOARD -> "the clipboard"
                    CefriumBrowser.PERMISSION_NFC -> "NFC"
                    else -> "a device capability"
                }
                permission(browser, "Allow $origin?", "This site wants to use $name.") { allowed ->
                    callback.respond(allowed)
                }
            }
        })
        browser.setHttpAuthHandler(object : CefriumBrowser.HttpAuthHandler {
            override fun onHttpAuthRequest(host: String, realm: String, unusedPort: Int, unusedIsMain: Boolean, callback: CefriumBrowser.HttpAuthCallback) {
                if (!present(browser, { callback.cancel() }) { builder, done ->
                    val username = EditText(activity).apply { hint = "Username" }
                    val password = EditText(activity).apply { hint = "Password"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
                    val fields = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 0, 32, 0); addView(username); addView(password) }
                    val site = host + realm.takeIf { it.isNotEmpty() }?.let { " ($it)" }.orEmpty()
                    builder.setTitle("Sign in").setMessage(site).setView(fields)
                        .setPositiveButton("Sign in") { _, _ -> done(); callback.proceed(username.text.toString(), password.text.toString()) }
                        .setNegativeButton("Cancel") { _, _ -> done(); callback.cancel() }
                }) callback.cancel()
            }
        })
        browser.setChromeClient(object : CefriumChromeClient {
            override fun onShowFileChooser(browser: CefriumBrowser, params: CefriumFileChooserParams, callback: CefriumFileChooserCallback): Boolean {
                return fileChooser(browser, params, callback)
            }
        })
    }

    fun permission(browser: CefriumBrowser, title: String, message: String, answer: (Boolean) -> Unit) {
        if (!owns(browser) || !canPresent()) { answer(false); return }
        dismiss()
        activeSession = browser
        var answered = false
        val finish: (Boolean) -> Unit = { allow -> if (!answered) { answered = true; cancel = null; activeSession = null; answer(allow && owns(browser)) } }
        cancel = { finish(false) }
        dialog = AlertDialog.Builder(activity).setTitle(title).setMessage(message)
            .setPositiveButton("Allow") { _, _ -> finish(true) }
            .setNegativeButton("Don't allow") { _, _ -> finish(false) }
            .setOnCancelListener { finish(false) }.create().also { it.show() }
    }

    /**
     * One prompt surface for every handler kind. onExternalCancel runs when
     * ownership is missing, the dialog is revoked (dismiss/dismissForBackground),
     * or the user cancels, so every Cefrium callback resolves exactly once.
     */
    private fun present(browser: CefriumBrowser, onExternalCancel: () -> Unit,
                        afterShow: (AlertDialog, () -> Unit) -> Unit = { _, _ -> },
                        build: (AlertDialog.Builder, () -> Unit) -> Unit): Boolean {
        if (!owns(browser) || !canPresent()) return false
        dismiss()
        activeSession = browser
        var answered = false
        var ownedDialog: AlertDialog? = null
        val done: () -> Unit = {
            if (!answered) {
                answered = true; cancel = null; activeSession = null
                dismissAttached(ownedDialog)
                if (dialog === ownedDialog) dialog = null
            }
        }
        cancel = { done(); onExternalCancel() }
        val alert = AlertDialog.Builder(activity)
        build(alert, done)
        alert.setOnCancelListener { done(); onExternalCancel() }
        ownedDialog = alert.create().also { created ->
            dialog = created
            created.setOnShowListener { afterShow(created, done) }
            created.show()
        }
        return true
    }

    private fun jsDialog(browser: CefriumBrowser, type: Int, title: String, message: String, callback: CefriumBrowser.JsDialogCallback) {
        val respond: (Boolean, String?) -> Unit = { ok, value -> callback.continueDialog(ok, value) }
        when (type) {
            CefriumBrowser.JS_DIALOG_ALERT ->
                if (!present(browser, { respond(false, null) }) { builder, done ->
                    builder.setTitle(title.ifEmpty { "Website" }).setMessage(message)
                        .setPositiveButton("OK") { _, _ -> done(); respond(true, null) }
                }) respond(false, null)
            CefriumBrowser.JS_DIALOG_CONFIRM ->
                if (!present(browser, { respond(false, null) }) { builder, done ->
                    builder.setTitle(title.ifEmpty { "Website" }).setMessage(message)
                        .setPositiveButton("OK") { _, _ -> done(); respond(true, null) }
                        .setNegativeButton("Cancel") { _, _ -> done(); respond(false, null) }
                }) respond(false, null)
            CefriumBrowser.JS_DIALOG_PROMPT ->
                if (!present(browser, { respond(false, null) }) { builder, done ->
                    // Cefrium carries no default-value field on JS prompt dialogs.
                    val input = EditText(activity)
                    builder.setTitle(title.ifEmpty { "Website" }).setMessage(message).setView(input)
                        .setPositiveButton("OK") { _, _ -> done(); respond(true, input.text.toString()) }
                        .setNegativeButton("Cancel") { _, _ -> done(); respond(false, null) }
                }) respond(false, null)
            else -> respond(false, null)
        }
    }

    private fun selectDialog(browser: CefriumBrowser, items: Array<CefriumPickerHandler.SelectItem>, defaultIndex: Int,
                            multiple: Boolean, callback: CefriumPickerHandler.SelectCallback) {
        // Cefrium flattens option groups into the array itself, so the label
        // indent only communicates depth, never changes the answer indices.
        var depth = 0
        val labels = items.map { item ->
            if (item.type == CefriumPickerHandler.SelectItem.SEPARATOR) depth = 0
            val label = "  ".repeat(depth) + if (item.type == CefriumPickerHandler.SelectItem.SEPARATOR) "────────" else item.label
            if (item.type == CefriumPickerHandler.SelectItem.GROUP) depth += 1
            label
        }
        val adapter = object : ArrayAdapter<String>(activity,
            if (multiple) android.R.layout.simple_list_item_multiple_choice else android.R.layout.simple_list_item_single_choice, labels) {
            override fun areAllItemsEnabled() = false
            override fun isEnabled(position: Int) = items[position].enabled
        }
        if (!present(browser, { callback.cancel() }) { builder, done ->
            builder.setTitle("Choose an option").setNegativeButton("Cancel") { _, _ -> done(); callback.cancel() }
            if (multiple) {
                val list = ListView(activity).apply {
                    choiceMode = ListView.CHOICE_MODE_MULTIPLE
                    this.adapter = adapter
                    items.forEachIndexed { index, item -> setItemChecked(index, item.checked && item.type != CefriumPickerHandler.SelectItem.GROUP) }
                }
                builder.setView(list).setPositiveButton("Done") { _, _ ->
                    done(); callback.select(items.indices.filter { list.isItemChecked(it) }.toIntArray())
                }
            } else {
                builder.setSingleChoiceItems(adapter, defaultIndex) { _, index ->
                    if (items[index].enabled) { done(); callback.select(intArrayOf(index)) }
                }
            }
        }) callback.cancel()
    }

    private fun dateTimeDialog(browser: CefriumBrowser, type: CefriumDateTimeInputType, dialogValue: Double,
                               min: Double, max: Double, callback: CefriumPickerHandler.DateTimeCallback) {
        val kind = when (type) {
            CefriumDateTimeInputType.DATE -> Kind.DATE
            CefriumDateTimeInputType.DATETIME_LOCAL -> Kind.DATETIME_LOCAL
            CefriumDateTimeInputType.MONTH -> Kind.MONTH
            CefriumDateTimeInputType.TIME -> Kind.TIME
            CefriumDateTimeInputType.WEEK -> Kind.WEEK
        }
        // Cefrium exchanges date/time values as doubles: seconds since midnight
        // for TIME, epoch seconds for the date kinds; NaN means unset.
        val initial = kindText(kind, dialogValue)
        val editor = dateEditor(kind, initial, kindText(kind, min), kindText(kind, max))
        if (!present(browser, { callback.cancel() }, afterShow = { alert, done ->
            alert.getButton(android.content.DialogInterface.BUTTON_POSITIVE).setOnClickListener {
                val value = editor.value()
                if (WebFormValues.allowed(kind, value, kindText(kind, min), kindText(kind, max), null, initial)) {
                    done(); callback.set(kindValue(kind, value))
                } else editor.error.text = "Choose a value within this form's allowed range and step."
            }
        }) { builder, done ->
            builder.setTitle("Choose ${if (kind == Kind.TIME) "a time" else "a date"}")
                .setView(ScrollView(activity).apply { addView(editor.view) }).setPositiveButton("Set", null)
                .setNegativeButton("Cancel") { _, _ -> done(); callback.cancel() }
        }) callback.cancel()
    }

    private fun kindText(kind: Kind, value: Double): String? {
        if (value.isNaN()) return null
        return when (kind) {
            Kind.TIME -> {
                val clock = LocalTime.ofSecondOfDay(value.toLong().coerceIn(0, 86399))
                String.format(Locale.ROOT, "%02d:%02d:%02d", clock.hour, clock.minute, clock.second)
            }
            Kind.DATE -> WebFormValues.dateText(LocalDate.ofInstant(Instant.ofEpochSecond(value.toLong()), ZoneOffset.UTC))
            Kind.DATETIME_LOCAL -> {
                val local = LocalDateTime.ofInstant(Instant.ofEpochSecond(value.toLong()), ZoneOffset.UTC)
                WebFormValues.dateText(local.toLocalDate()) + "T" + local.toLocalTime()
            }
            Kind.MONTH -> {
                val month = YearMonth.from(LocalDate.ofInstant(Instant.ofEpochSecond(value.toLong()), ZoneOffset.UTC))
                String.format(Locale.ROOT, "%04d-%02d", month.year, month.monthValue)
            }
            Kind.WEEK -> {
                val day = LocalDate.ofInstant(Instant.ofEpochSecond(value.toLong()), ZoneOffset.UTC)
                String.format(Locale.ROOT, "%04d-W%02d", day.get(IsoFields.WEEK_BASED_YEAR), day.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR))
            }
        }
    }

    private fun kindValue(kind: Kind, canonical: String): Double {
        return when (kind) {
            Kind.TIME -> WebFormValues.time(canonical).toSecondOfDay().toDouble()
            Kind.DATE -> WebFormValues.date(canonical).atStartOfDay().toInstant(ZoneOffset.UTC).epochSecond.toDouble()
            Kind.DATETIME_LOCAL -> WebFormValues.date(canonical.substringBefore('T'))
                .atTime(WebFormValues.time(canonical.substringAfter('T'))).toInstant(ZoneOffset.UTC).epochSecond.toDouble()
            Kind.MONTH -> {
                val parts = canonical.split('-')
                LocalDate.of(parts[0].toInt(), parts[1].toInt(), 1).atStartOfDay().toInstant(ZoneOffset.UTC).epochSecond.toDouble()
            }
            Kind.WEEK -> {
                val year = canonical.substringBefore('-').toInt()
                val week = canonical.substringAfter('W').toInt()
                LocalDate.of(year, 1, 4).with(IsoFields.WEEK_OF_WEEK_BASED_YEAR, week.toLong())
                    .with(java.time.temporal.ChronoField.DAY_OF_WEEK, 1).atStartOfDay().toInstant(ZoneOffset.UTC).epochSecond.toDouble()
            }
        }
    }

    private fun colorDialog(browser: CefriumBrowser, defaultColor: Int, presets: IntArray?, callback: CefriumPickerHandler.ColorCallback) {
        val initial = "#%06X".format(Locale.ROOT, defaultColor and 0xFFFFFF)
        val input = EditText(activity).apply {
            hint = "#336699"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            filters = arrayOf(InputFilter.LengthFilter(7)); setText(initial)
            contentDescription = "Hex color"
        }
        val fields = column().apply {
            addView(input)
            presets?.take(24)?.forEach { color ->
                addView(TextView(activity).apply { text = "#%06X".format(Locale.ROOT, color and 0xFFFFFF); setTextColor(color); setPadding(16, 16, 16, 16); setOnClickListener { input.setText("#%06X".format(Locale.ROOT, color and 0xFFFFFF)) } })
            }
        }
        if (!present(browser, { callback.cancel() }, afterShow = { alert, done ->
            alert.getButton(android.content.DialogInterface.BUTTON_POSITIVE).setOnClickListener {
                val value = input.text.toString()
                if (value.matches(Regex("#[0-9a-fA-F]{6}"))) { done(); callback.set(Color.parseColor(value.lowercase(Locale.ROOT))) }
                else input.error = "Use a color such as #336699"
            }
        }) { builder, done ->
            builder.setTitle("Choose a color").setView(ScrollView(activity).apply { addView(fields) })
                .setPositiveButton("Set", null).setNegativeButton("Cancel") { _, _ -> done(); callback.cancel() }
        }) callback.cancel()
    }

    private fun fileChooser(browser: CefriumBrowser, params: CefriumFileChooserParams, callback: CefriumFileChooserCallback): Boolean {
        // Cefrium's SAVE and OPEN_FOLDER modes have no upload counterpart; CefriumBrowser
        // only surfaces them as save dialogs the engine handles elsewhere, so refuse both.
        if (params.mode != CefriumFileChooserParams.Mode.OPEN && params.mode != CefriumFileChooserParams.Mode.OPEN_MULTIPLE) {
            callback.cancel(); return true
        }
        if (!owns(browser) || !canPresent()) { callback.cancel(); return true }
        dismiss()
        activeSession = browser
        var answered = false
        val finish: (List<Uri>) -> Unit = { files ->
            if (!answered) {
                answered = true; cancel = null; activeSession = null
                clearPickerLease()
                if (files.isNotEmpty() && owns(browser)) callback.select(files.map(Uri::toString).toTypedArray())
                else callback.cancel()
            }
        }
        val cancelPicker: () -> Unit = { finish(emptyList()) }
        cancel = cancelPicker
        externalFilePrompt = true
        pickerTimeout = Runnable { if (cancel === cancelPicker) dismiss() }.also { handler.postDelayed(it, 5 * 60 * 1000L) }
        val accept = params.acceptTypes.ifEmpty { listOf("*/*") }.toTypedArray()
        requestFiles(accept) { files -> finish(files) }
        return true
    }

    private fun column() = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        val inset = (20 * activity.resources.displayMetrics.density).toInt()
        setPadding(inset, 8, inset, 8)
    }

    private data class DateEditor(val view: LinearLayout, val error: TextView, val value: () -> String)

    private fun dateEditor(kind: Kind, initial: String?, min: String?, max: String?): DateEditor {
        val fields = column()
        val error = TextView(activity).apply { setTextColor(Color.rgb(170, 25, 25)); accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        val normalized = WebFormValues.parse(kind, initial)?.canonical
        var read: () -> String = { "" }
        val numericYear = normalized?.substringBefore('-')?.toIntOrNull()
        if (numericYear != null && numericYear > 9999 || listOfNotNull(min, max).any { it.substringBefore('-').toIntOrNull()?.let { year -> year > 9999 } == true }) {
            val input = EditText(activity).apply { inputType = InputType.TYPE_CLASS_DATETIME; setText(normalized.orEmpty()); hint = "Year, month and day" }
            fields.addView(input); read = { input.text.toString() }
        } else when (kind) {
            Kind.DATE, Kind.DATETIME_LOCAL -> {
                val day = normalized?.substringBefore('T')?.let { runCatching { WebFormValues.date(it) }.getOrNull() } ?: LocalDate.now()
                val picker = DatePicker(activity).apply {
                    minDate = LocalDate.of(1, 1, 1).atStartOfDay(ZoneOffset.systemDefault()).toInstant().toEpochMilli()
                    maxDate = LocalDate.of(9999, 12, 31).atStartOfDay(ZoneOffset.systemDefault()).toInstant().toEpochMilli()
                    init(day.year, day.monthValue - 1, day.dayOfMonth, null)
                }
                fields.addView(picker)
                val time = if (kind == Kind.DATETIME_LOCAL) timeEditor(fields, normalized?.substringAfter('T')) else null
                read = { WebFormValues.dateText(LocalDate.of(picker.year, picker.month + 1, picker.dayOfMonth)) + (time?.let { "T" + it() } ?: "") }
            }
            Kind.TIME -> read = timeEditor(fields, normalized)
            Kind.MONTH, Kind.WEEK -> {
                val today = LocalDate.now()
                val year = number(fields, "Year", 1, 9999, numericYear ?: if (kind == Kind.WEEK) today.get(IsoFields.WEEK_BASED_YEAR) else today.year)
                val number = number(fields, if (kind == Kind.MONTH) "Month" else "Week", 1, if (kind == Kind.MONTH) 12 else 53,
                    normalized?.substringAfterLast(if (kind == Kind.MONTH) '-' else 'W')?.toIntOrNull() ?: if (kind == Kind.MONTH) today.monthValue else today.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR))
                read = { String.format(Locale.ROOT, if (kind == Kind.MONTH) "%04d-%02d" else "%04d-W%02d", year.value, number.value) }
            }
        }
        if (!min.isNullOrBlank()) fields.addView(TextView(activity).apply { text = "Earliest: $min" })
        if (!max.isNullOrBlank()) fields.addView(TextView(activity).apply { text = "Latest: $max" })
        fields.addView(error)
        return DateEditor(fields, error, read)
    }

    private fun number(fields: LinearLayout, label: String, low: Int, high: Int, current: Int): NumberPicker {
        val picker = NumberPicker(activity).apply { id = View.generateViewId(); minValue = low; maxValue = high; value = current.coerceIn(low, high); wrapSelectorWheel = false; contentDescription = label }
        fields.addView(TextView(activity).apply { text = label; labelFor = picker.id })
        fields.addView(picker)
        return picker
    }

    private fun timeEditor(fields: LinearLayout, initial: String?): () -> String {
        val time = initial?.let { runCatching { WebFormValues.time(it) }.getOrNull() } ?: LocalTime.now().withSecond(0).withNano(0)
        val picker = TimePicker(activity).apply { setIs24HourView(android.text.format.DateFormat.is24HourFormat(activity)); hour = time.hour; minute = time.minute }
        fields.addView(picker)
        val seconds = number(fields, "Seconds", 0, 59, time.second)
        val fraction = EditText(activity).apply {
            hint = "Fractional seconds"; inputType = InputType.TYPE_CLASS_NUMBER; filters = arrayOf(InputFilter.LengthFilter(9))
            if (time.nano != 0) setText(String.format(Locale.ROOT, "%09d", time.nano).trimEnd('0'))
        }
        fields.addView(fraction)
        return { String.format(Locale.ROOT, "%02d:%02d:%02d", picker.hour, picker.minute, seconds.value) + fraction.text.toString().takeIf { it.isNotEmpty() }?.let { ".$it" }.orEmpty() }
    }
}