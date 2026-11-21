package dev.yab.browser.engine

import android.app.Activity
import android.app.AlertDialog
import android.content.DialogInterface
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
import dev.yab.browser.model.WebFormValues
import dev.yab.browser.model.WebFormValues.Kind
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.temporal.IsoFields
import java.util.Locale
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoSession

/** Native answers stay bound to the initiating session and document. */
class NativePagePrompts(
    private val activity: Activity,
    private val owns: (GeckoSession) -> Boolean,
    private val canPresent: () -> Boolean = { true },
    private val requestFiles: (Array<String>, (List<Uri>) -> Unit) -> Unit,
) : GeckoSession.PromptDelegate {
    /** The interstitial bridge: asked before any dialog shows, so a resource
     * error page can speak with the browser without a dialog. Null answer
     * falls through to the page's own dialog. */
    var textBridge: ((GeckoSession.PromptDelegate.TextPrompt) -> GeckoResult<GeckoSession.PromptDelegate.PromptResponse>?)? = null
    private var dialog: AlertDialog? = null
    private val mutablePending = kotlinx.coroutines.flow.MutableStateFlow(false)
    val pending: kotlinx.coroutines.flow.StateFlow<Boolean> = mutablePending
    private var cancel: (() -> Unit)? = null
        set(value) { field = value; mutablePending.value = value != null }
    private var activeSession: GeckoSession? = null
    private val handler = Handler(Looper.getMainLooper())
    private var externalFilePrompt = false
    private var pickerTimeout: Runnable? = null

    fun hasPending(session: GeckoSession): Boolean = activeSession === session && cancel != null
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

    fun permission(session: GeckoSession, title: String, message: String, answer: (Boolean) -> Unit) {
        if (!owns(session) || !canPresent()) { answer(false); return }
        dismiss()
        activeSession = session
        var answered = false
        val finish: (Boolean) -> Unit = { allow -> if (!answered) { answered = true; cancel = null; activeSession = null; answer(allow && owns(session)) } }
        cancel = { finish(false) }
        dialog = AlertDialog.Builder(activity).setTitle(title).setMessage(message)
            .setPositiveButton("Allow") { _, _ -> finish(true) }
            .setNegativeButton("Don't allow") { _, _ -> finish(false) }
            .setOnCancelListener { finish(false) }.create().also { it.show() }
    }

    private fun respond(session: GeckoSession, prompt: GeckoSession.PromptDelegate.BasePrompt,
                        canceled: () -> GeckoSession.PromptDelegate.PromptResponse = { prompt.dismiss() },
                        afterShow: (AlertDialog, (() -> GeckoSession.PromptDelegate.PromptResponse) -> Unit) -> Unit = { _, _ -> },
                        builder: (AlertDialog.Builder, (() -> GeckoSession.PromptDelegate.PromptResponse) -> Unit) -> Unit): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        if (!owns(session) || !canPresent()) return GeckoResult.fromValue(canceled())
        dismiss()
        activeSession = session
        val result = GeckoResult<GeckoSession.PromptDelegate.PromptResponse>()
        var answered = false
        var ownedDialog: AlertDialog? = null
        val finish: (() -> GeckoSession.PromptDelegate.PromptResponse) -> Unit = { response ->
            if (!answered) {
                answered = true; cancel = null; activeSession = null
                prompt.setDelegate(null)
                dismissAttached(ownedDialog)
                if (dialog === ownedDialog) dialog = null
                if (prompt.isComplete) result.completeExceptionally(IllegalStateException("The page dismissed its prompt"))
                else result.complete(response())
            }
        }
        val done: (() -> GeckoSession.PromptDelegate.PromptResponse) -> Unit = { response ->
            if (!answered) finish { if (owns(session)) response() else canceled() }
        }
        cancel = { finish(canceled) }
        prompt.setDelegate(object : GeckoSession.PromptDelegate.PromptInstanceDelegate {
            override fun onPromptDismiss(prompt: GeckoSession.PromptDelegate.BasePrompt) { finish(canceled) }
            override fun onPromptUpdate(prompt: GeckoSession.PromptDelegate.BasePrompt) { finish(canceled) }
        })
        val alert = AlertDialog.Builder(activity).setTitle(prompt.title ?: "Website")
        builder(alert, done)
        alert.setOnCancelListener { finish(canceled) }
        ownedDialog = alert.create().also { created ->
            dialog = created
            created.setOnShowListener { afterShow(created, done) }
            created.show()
        }
        return result
    }

    override fun onAlertPrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.AlertPrompt) = respond(session, prompt) { builder, done ->
        builder.setMessage(prompt.message).setPositiveButton("OK") { _, _ -> done { prompt.dismiss() } }
    }
    override fun onButtonPrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.ButtonPrompt) = respond(session, prompt) { builder, done ->
        builder.setMessage(prompt.message)
            .setPositiveButton("OK") { _, _ -> done { prompt.confirm(GeckoSession.PromptDelegate.ButtonPrompt.Type.POSITIVE) } }
            .setNegativeButton("Cancel") { _, _ -> done { prompt.confirm(GeckoSession.PromptDelegate.ButtonPrompt.Type.NEGATIVE) } }
    }
    override fun onTextPrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.TextPrompt): GeckoResult<GeckoSession.PromptDelegate.PromptResponse>? {
        textBridge?.let { bridge -> bridge(prompt)?.let { return it } }
        return respond(session, prompt) { builder, done ->
            val input = EditText(activity).apply { setText(prompt.defaultValue) }
            builder.setMessage(prompt.message).setView(input)
                .setPositiveButton("OK") { _, _ -> done { prompt.confirm(input.text.toString()) } }
                .setNegativeButton("Cancel") { _, _ -> done { prompt.dismiss() } }
        }
    }

    override fun onBeforeUnloadPrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.BeforeUnloadPrompt) =
        respond(session, prompt, canceled = { prompt.confirm(AllowOrDeny.DENY) }) { builder, done ->
            builder.setTitle("Leave this page?").setMessage("Changes you made may not be saved.")
                .setPositiveButton("Leave") { _, _ -> done { prompt.confirm(AllowOrDeny.ALLOW) } }
                .setNegativeButton("Stay") { _, _ -> done { prompt.confirm(AllowOrDeny.DENY) } }
        }

    override fun onRepostConfirmPrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.RepostConfirmPrompt) =
        respond(session, prompt, canceled = { prompt.confirm(AllowOrDeny.DENY) }) { builder, done ->
            builder.setTitle("Send this form again?").setMessage("This page needs to resend the information you submitted.")
                .setPositiveButton("Resend") { _, _ -> done { prompt.confirm(AllowOrDeny.ALLOW) } }
                .setNegativeButton("Cancel") { _, _ -> done { prompt.confirm(AllowOrDeny.DENY) } }
        }

    override fun onPopupPrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.PopupPrompt) =
        respond(session, prompt, canceled = { prompt.confirm(AllowOrDeny.DENY) }) { builder, done ->
            builder.setTitle("Open another page?").setMessage(prompt.targetUri ?: "This website wants to open a popup.")
                .setPositiveButton("Allow") { _, _ -> done { prompt.confirm(AllowOrDeny.ALLOW) } }
                .setNegativeButton("Don't allow") { _, _ -> done { prompt.confirm(AllowOrDeny.DENY) } }
        }

    override fun onChoicePrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.ChoicePrompt): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        data class Row(val choice: GeckoSession.PromptDelegate.ChoicePrompt.Choice, val label: String, val enabled: Boolean)
        val rows = mutableListOf<Row>()
        fun append(choices: Array<GeckoSession.PromptDelegate.ChoicePrompt.Choice>, parentDisabled: Boolean = false, depth: Int = 0) {
            if (depth > 32) return
            for (choice in choices) {
                val group = choice.items
                rows += Row(choice, "  ".repeat(depth) + if (choice.separator) "────────" else choice.label,
                    group == null && !choice.separator && !choice.disabled && !parentDisabled)
                if (group != null) append(group, parentDisabled || choice.disabled, depth + 1)
            }
        }
        append(prompt.choices)
        val multiple = prompt.type == GeckoSession.PromptDelegate.ChoicePrompt.Type.MULTIPLE
        val adapter = object : ArrayAdapter<String>(activity,
            if (multiple) android.R.layout.simple_list_item_multiple_choice else android.R.layout.simple_list_item_single_choice, rows.map { it.label }) {
            override fun areAllItemsEnabled() = false
            override fun isEnabled(position: Int) = rows[position].enabled
        }
        return respond(session, prompt) { builder, done ->
            builder.setTitle(prompt.title ?: prompt.message ?: "Choose an option").setNegativeButton("Cancel") { _, _ -> done { prompt.dismiss() } }
            if (multiple) {
                val list = ListView(activity).apply {
                    choiceMode = ListView.CHOICE_MODE_MULTIPLE
                    this.adapter = adapter
                    rows.forEachIndexed { index, row -> setItemChecked(index, row.choice.selected && row.choice.items == null) }
                }
                builder.setView(list).setPositiveButton("Done") { _, _ ->
                    done { prompt.confirm(rows.indices.filter { rows[it].choice.items == null && !rows[it].choice.separator && list.isItemChecked(it) }.map { rows[it].choice.id }.toTypedArray()) }
                }
            } else {
                builder.setSingleChoiceItems(adapter, rows.indexOfFirst { it.choice.selected && it.choice.items == null }) { _, index ->
                    if (rows[index].enabled) done { prompt.confirm(rows[index].choice.id) }
                }
            }
        }
    }

    override fun onColorPrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.ColorPrompt): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        val input = EditText(activity).apply {
            hint = "#336699"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            filters = arrayOf(InputFilter.LengthFilter(7)); setText(prompt.defaultValue ?: "#000000")
            contentDescription = "Hex color"
        }
        val fields = column().apply {
            addView(input)
            prompt.predefinedValues?.filter { it.matches(Regex("#[0-9a-fA-F]{6}")) }?.take(24)?.forEach { color ->
                addView(TextView(activity).apply { text = color; setTextColor(Color.parseColor(color)); setPadding(16, 16, 16, 16); setOnClickListener { input.setText(color) } })
            }
        }
        return respond(session, prompt, afterShow = { alert, done ->
            alert.getButton(DialogInterface.BUTTON_POSITIVE).setOnClickListener {
                val value = input.text.toString()
                if (value.matches(Regex("#[0-9a-fA-F]{6}"))) done { prompt.confirm(value.lowercase(Locale.ROOT)) }
                else input.error = "Use a color such as #336699"
            }
        }) { builder, done ->
            builder.setTitle(prompt.title ?: "Choose a color").setView(ScrollView(activity).apply { addView(fields) })
                .setPositiveButton("Set", null).setNegativeButton("Cancel") { _, _ -> done { prompt.dismiss() } }
        }
    }

    override fun onDateTimePrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.DateTimePrompt): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        val kind = Kind.entries.getOrNull(prompt.type - 1) ?: return GeckoResult.fromValue(prompt.dismiss())
        val editor = dateEditor(kind, prompt.defaultValue, prompt.minValue, prompt.maxValue)
        return respond(session, prompt, afterShow = { alert, done ->
            alert.getButton(DialogInterface.BUTTON_POSITIVE).setOnClickListener {
                val value = editor.value()
                if (WebFormValues.allowed(kind, value, prompt.minValue, prompt.maxValue, prompt.stepValue, prompt.defaultValue)) {
                    done { prompt.confirm(WebFormValues.parse(kind, value)!!.canonical) }
                } else editor.error.text = "Choose a value within this form's allowed range and step."
            }
        }) { builder, done ->
            builder.setTitle(prompt.title ?: "Choose ${if (kind == Kind.TIME) "a time" else "a date"}")
                .setView(ScrollView(activity).apply { addView(editor.view) }).setPositiveButton("Set", null)
                .setNeutralButton("Clear") { _, _ -> done { prompt.confirm("") } }
                .setNegativeButton("Cancel") { _, _ -> done { prompt.dismiss() } }
        }
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
                    minDate = LocalDate.of(1, 1, 1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
                    maxDate = LocalDate.of(9999, 12, 31).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
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
    override fun onAuthPrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.AuthPrompt) = respond(session, prompt) { builder, done ->
        val username = EditText(activity).apply { hint = "Username"; setText(prompt.authOptions.username) }
        val password = EditText(activity).apply { hint = "Password"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        val fields = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 0, 32, 0); addView(username); addView(password) }
        builder.setMessage(prompt.authOptions.uri).setView(fields)
            .setPositiveButton("Sign in") { _, _ -> done { prompt.confirm(username.text.toString(), password.text.toString()) } }
            .setNegativeButton("Cancel") { _, _ -> done { prompt.dismiss() } }
    }
    override fun onFilePrompt(session: GeckoSession, prompt: GeckoSession.PromptDelegate.FilePrompt): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        if (!owns(session) || !canPresent() || prompt.type == GeckoSession.PromptDelegate.FilePrompt.Type.FOLDER) return GeckoResult.fromValue(prompt.dismiss())
        dismiss()
        activeSession = session
        val result = GeckoResult<GeckoSession.PromptDelegate.PromptResponse>()
        var answered = false
        val finish: (List<Uri>) -> Unit = { files ->
            if (!answered) {
                answered = true; cancel = null; activeSession = null; prompt.setDelegate(null)
                clearPickerLease()
                if (prompt.isComplete) result.completeExceptionally(IllegalStateException("The page dismissed its file picker"))
                else result.complete(if (owns(session) && files.isNotEmpty()) {
                    prompt.confirm(activity, (if (prompt.type == GeckoSession.PromptDelegate.FilePrompt.Type.SINGLE) files.take(1) else files).toTypedArray())
                } else prompt.dismiss())
            }
        }
        val cancelPicker: () -> Unit = { finish(emptyList()) }
        cancel = cancelPicker
        externalFilePrompt = true
        pickerTimeout = Runnable { if (cancel === cancelPicker) dismiss() }.also { handler.postDelayed(it, 5 * 60 * 1000L) }
        prompt.setDelegate(object : GeckoSession.PromptDelegate.PromptInstanceDelegate {
            override fun onPromptDismiss(prompt: GeckoSession.PromptDelegate.BasePrompt) { finish(emptyList()) }
        })
        requestFiles(prompt.mimeTypes ?: arrayOf("*/*")) { files ->
            finish(files)
        }
        return result
    }
}
