package dev.yab.agent

import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MacSendTest {
    private class Disk : ChatPersistence {
        var saved = ChatSnapshot()
        override suspend fun load() = saved
        override suspend fun save(snapshot: ChatSnapshot) { saved = snapshot }
    }
    private class Port : RemoteAgentTransport {
        val sleeping = RemoteMac("sleeping", "MacBook", false, setOf(AgentProvider.CLAUDE), takesFiles = true, availability = MacAvailability(MacPhase.ASLEEP, 100))
        val awake = RemoteMac("awake", "Mac mini", true, setOf(AgentProvider.CLAUDE), takesFiles = true)
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(sleeping, awake), sleeping.id, 7))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        override val sends = MutableStateFlow(emptyList<RemoteSend>())
        val commands = mutableListOf<AgentSendCommand>()
        val bytes = byteArrayOf(1, 2, 3)
        val file = PreparedAttachment(ChatFile("file.txt", "text/plain", 3, "digest"), bytes)
        var cancelled = 0; var moved = 0; var retried = 0
        var cancellationGate: CompletableDeferred<Unit>? = null
        var cancellationStarted: CompletableDeferred<Unit>? = null
        fun status(id: String = "send", chat: String = "draft", state: MacSendState = MacSendState.WAITING) = RemoteSend("account", 7, id, chat,
            sleeping.id, AgentProvider.CLAUDE, 1000, state, "Question", listOf(file.file), "fingerprint-$id-$state")
        override suspend fun send(command: AgentSendCommand): AgentSendReceipt {
            commands += command
            val send = status(command.id, command.clientChat).copy(mac = command.mac, sentAt = 2000, files = command.files.map { it.file }, question = command.question.words)
            sends.value = sends.value + send
            return AgentSendReceipt(command.owner, send)
        }
        override suspend fun cancelSend(expected: RemoteSend, sourceCurrent: () -> Boolean): MacSendDraft? {
            cancellationStarted?.complete(Unit); cancellationGate?.await()
            require(sourceCurrent() && sends.value.any { it == expected } && expected.state == MacSendState.WAITING)
            cancelled++; sends.value = sends.value.map { if (it.id == expected.id) it.copy(state = MacSendState.CANCELLED, fingerprint = "cancelled") else it }
            return MacSendDraft(expected.question, if (expected.files.isEmpty()) emptyList() else listOf(file), expected.provider)
        }
        override suspend fun redirectPending(expected: RemoteSend, mac: String, clientChat: String, sourceCurrent: () -> Boolean): RemoteSend? {
            require(sourceCurrent() && sends.value.any { it == expected } && expected.state == MacSendState.WAITING)
            moved++
            val next = expected.copy(id = "redirect-$moved", clientChat = clientChat, mac = mac, sentAt = 3000, fingerprint = "redirect-$moved")
            sends.value = sends.value.map { if (it.id == expected.id) it.copy(state = MacSendState.CANCELLED, fingerprint = "cancelled") else it } + next
            return next
        }
        override suspend fun resendSend(expected: RemoteSend, sourceCurrent: () -> Boolean): RemoteSend? {
            require(sourceCurrent() && sends.value.any { it == expected } && expected.state in setOf(MacSendState.FAILED, MacSendState.EXPIRED))
            retried++; return expected.copy(id = "retry-$retried", state = MacSendState.WAITING, sentAt = 4000, fingerprint = "retry-$retried").also { sends.value = sends.value + it }
        }
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) {}
    }

    @Test fun aRemoteQuickAnswerPromotesOnDurableQueueAndKeepsTheActualSendMacAfterAutoChanges() = runTest {
        val port = Port(); val disk = Disk(); val repository = AgentRepository(disk, UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent()
        val id = repository.newChat(ephemeral = true, forceMac = true); repository.draft("Question"); repository.send(chatId = id); runCurrent()
        val queued = repository.state.value.current!!
        assertFalse(queued.ephemeral); assertEquals(port.sleeping.id, queued.pendingSend!!.mac)
        assertTrue(disk.saved.chats.any { it.id == id && !it.ephemeral && it.pendingSend != null })
        port.connection.value = port.connection.value.copy(selectedMac = port.awake.id); runCurrent()
        assertEquals(port.awake.id, repository.state.value.connection.route(AgentProvider.CLAUDE)!!.id)
        assertEquals(port.sleeping.id, repository.state.value.current!!.pendingSend!!.mac)
        assertNull(repository.state.value.current!!.owner)
    }

    @Test fun dontSendRestoresTheExactQuestionAndFilesAndDoesNotDeleteTheConversation() = runTest {
        val port = Port(); val initial = port.status(); port.sends.value = listOf(initial)
        val repository = AgentRepository(Disk(), UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent(); repository.open(initial.clientChat)
        repository.dontSend(initial.clientChat); runCurrent()
        val chat = repository.state.value.current!!
        assertEquals("Question", chat.draft); assertEquals(DeliveryState.IDLE, chat.delivery); assertNull(chat.pendingSend)
        assertTrue(chat.messages.none { it.id == initial.id }); assertEquals(1, port.cancelled)
        assertArrayEquals(port.bytes, repository.state.value.attachments[chat.id]!!.single().bytes)
        assertEquals(port.sleeping.id, port.connection.value.selectedMac)
    }

    @Test fun offeredMacIsConsumedOnlyByANewRequestAndNeverChangesManualChoiceOrTheAcceptedOwner() = runTest {
        val port = Port(); val initial = port.status(); port.sends.value = listOf(initial)
        val repository = AgentRepository(Disk(), UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent(); repository.open(initial.clientChat)
        repository.askOnOtherMac(initial.clientChat, port.awake.id); runCurrent()
        val next = repository.state.value.current!!
        assertNotEquals(initial.clientChat, next.id); assertEquals(port.awake.id, next.pendingSend!!.mac)
        assertEquals(port.sleeping.id, port.connection.value.selectedMac); assertNull(next.owner); assertEquals(1, port.moved)
        assertEquals(initial.files, next.pendingSend!!.files)
        assertTrue(repository.state.value.chats.single { it.id == initial.clientChat }.messages.none { it.id == initial.id })
        val owner = RemoteOwner("account", port.sleeping.id, "a:accepted", AgentProvider.CLAUDE)
        port.conversations.value = listOf(RemoteConversation(null, owner, "Accepted", emptyList(), false)); runCurrent()
        repository.open(owner.chat); repository.draft("Continue"); repository.send(chatId = owner.chat)
        assertEquals(owner, port.commands.single().owner); assertEquals(owner.mac, port.commands.single().mac)
    }

    @Test fun ownerlessExpiredAndFailedStatusesRecoverFromTheJournalAndRetryTheOriginalTarget() = runTest {
        val port = Port(); val expired = port.status(state = MacSendState.EXPIRED); port.sends.value = listOf(expired)
        val repository = AgentRepository(Disk(), UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent(); repository.open(expired.clientChat)
        assertEquals(DeliveryState.FAILED, repository.state.value.current!!.delivery)
        assertTrue(repository.state.value.current!!.messages.any { it.role == MessageRole.FAILURE && it.text.contains("Expired before MacBook") })
        port.connection.value = port.connection.value.copy(selectedMac = port.awake.id); runCurrent()
        repository.sendAgain(expired.clientChat); runCurrent()
        assertEquals(port.sleeping.id, repository.state.value.current!!.pendingSend!!.mac)
        assertEquals(DeliveryState.QUEUED, repository.state.value.current!!.delivery); assertEquals(1, port.retried)
        val failed = port.sends.value.last().copy(state = MacSendState.FAILED, fingerprint = "failed", reason = "Provider signed out")
        port.sends.value = listOf(expired, failed); runCurrent()
        assertTrue(repository.state.value.current!!.messages.any { it.text.contains("Provider signed out") })
    }

    @Test fun aTombstoneCannotRemainQueuedAndPrivateOrChangedAccountCannotTakeBackThePublicSend() = runTest {
        val port = Port(); val pending = port.status(); port.sends.value = listOf(pending)
        val repository = AgentRepository(Disk(), UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent(); repository.open(pending.clientChat)
        for (state in listOf(MacSendState.PROCESSING, MacSendState.TAKEN)) {
            port.sends.value = listOf(pending.copy(state = state, fingerprint = state.name)); runCurrent()
            repository.dontSend(pending.clientChat); repository.askOnOtherMac(pending.clientChat, port.awake.id)
            assertEquals(0, port.cancelled); assertEquals(0, port.moved)
        }
        port.sends.value = emptyList(); runCurrent()
        assertNull(repository.state.value.current!!.pendingSend); assertEquals(DeliveryState.IDLE, repository.state.value.current!!.delivery)
        port.sends.value = listOf(pending); runCurrent()
        repository.setPrivacy(true); repository.dontSend(pending.clientChat); assertEquals(0, port.cancelled)
        repository.setPrivacy(false); repository.open(pending.clientChat)
        port.connection.value = port.connection.value.copy(account = "other", epoch = 8); runCurrent()
        assertNull(repository.state.value.current); assertTrue(repository.state.value.listed().isEmpty())
        repository.dontSend(pending.clientChat); assertEquals(0, port.cancelled)
    }

    @Test fun theConversationFrameMustRemainCurrentWhileCancellationAwaitsItsTransport() = runTest {
        val port = Port(); val pending = port.status(); port.sends.value = listOf(pending)
        port.cancellationGate = CompletableDeferred(); port.cancellationStarted = CompletableDeferred()
        val repository = AgentRepository(Disk(), UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent(); repository.open(pending.clientChat)
        var frameCurrent = true
        val cancellation = launch { repository.dontSend(pending.clientChat) { frameCurrent } }; runCurrent(); port.cancellationStarted!!.await()
        frameCurrent = false; port.cancellationGate!!.complete(Unit); cancellation.join(); runCurrent()
        assertEquals(0, port.cancelled); assertEquals(MacSendState.WAITING, port.sends.value.single().state)
        assertTrue(repository.state.value.attachments.isEmpty()); assertNull(repository.state.value.error)
    }

    @Test fun queuedAttachmentsCannotBorrowAutoAndPickerReadMustKeepTheExactEpochAndTarget() = runTest {
        val port = Port(); val pending = port.status(); port.sends.value = listOf(pending)
        val repository = AgentRepository(Disk(), UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent(); repository.open(pending.clientChat)
        assertFalse(repository.canAttach(repository.state.value.current!!)); assertNull(repository.attachmentLease(pending.clientChat))
        val id = repository.newChat(forceMac = true)
        val lease = repository.attachmentLease(id)!!
        assertEquals(port.sleeping.id, lease.mac)
        port.connection.value = port.connection.value.copy(selectedMac = port.awake.id); runCurrent()
        assertThrows(IllegalArgumentException::class.java) { repository.attach(id, listOf(port.file), lease) }
        assertTrue(repository.state.value.attachments[id].isNullOrEmpty())
        val current = repository.attachmentLease(id)!!
        port.connection.value = port.connection.value.copy(epoch = 8); runCurrent()
        assertThrows(IllegalArgumentException::class.java) { repository.attach(id, listOf(port.file), current) }
    }

    @Test fun anUnownedSendWaitingForLocalInferenceCannotBorrowANewerMacOrProviderChoice() = runTest {
        repeat(2) { changedChoice ->
            val port = Port(); val began = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val local = object : LocalAiAdapter { override suspend fun answer(question: LocalQuestion): String { began.complete(Unit); release.await(); return "Local answer" } }
            val repository = AgentRepository(Disk(), local, port)
            val collector = backgroundScope.launch { repository.run() }; runCurrent()
            val localChat = repository.newChat(ephemeral = true); repository.draft("Local question")
            val first = launch { repository.send(chatId = localChat) }; runCurrent(); began.await()
            val remote = repository.newChat(forceMac = true); repository.draft("Tapped for the original Mac")
            val waiting = launch(start = CoroutineStart.UNDISPATCHED) { repository.send(ModelSelection("old-mac-model"), chatId = remote) }
            if (changedChoice == 0) port.connection.value = port.connection.value.copy(selectedMac = port.awake.id)
            else repository.preferences(repository.state.value.preferences.copy(provider = AgentProvider.CODEX))
            release.complete(Unit); first.join(); waiting.join(); runCurrent()
            assertTrue(port.commands.isEmpty()); assertEquals("Tapped for the original Mac", repository.state.value.current!!.draft)
            assertTrue(repository.state.value.current!!.messages.isEmpty()); collector.cancelAndJoin()
        }
    }

    @Test fun terminalSendStatusAndTakenReceiptCannotBeOverwrittenByAnOlderHeadSnapshot() = runTest {
        val port = Port(); val pending = port.status().copy(chat = "a:accepted", tookAt = 3000)
        val owner = RemoteOwner("account", port.sleeping.id, "a:accepted", AgentProvider.CLAUDE)
        val head = RemoteConversation(pending.clientChat, owner, "Accepted", emptyList(), false, updatedAt = 2000, choices = listOf("Old choice"))
        port.sends.value = listOf(pending.copy(state = MacSendState.TAKEN)); port.conversations.value = listOf(head)
        val repository = AgentRepository(Disk(), UnavailableLocalAiAdapter(), port)
        backgroundScope.launch { repository.run() }; runCurrent(); repository.open(pending.clientChat)
        assertEquals(DeliveryState.ANSWERING, repository.state.value.current!!.delivery); assertTrue(repository.state.value.current!!.choices.isEmpty())
        port.conversations.value = listOf(head.copy(updatedAt = 4000)); runCurrent()
        assertEquals(DeliveryState.IDLE, repository.state.value.current!!.delivery); assertEquals(listOf("Old choice"), repository.state.value.current!!.choices)
        port.sends.value = listOf(pending.copy(state = MacSendState.EXPIRED, fingerprint = "expired")); runCurrent()
        port.conversations.value = listOf(head.copy(updatedAt = 5000, working = true)); runCurrent()
        assertEquals(DeliveryState.FAILED, repository.state.value.current!!.delivery)
        assertTrue(repository.state.value.current!!.messages.any { it.role == MessageRole.FAILURE && it.text.contains("Expired") })
    }

    @Test fun tenHourWarningUsesTheOriginalSendTimeAndTwelveHourDeadlineWithoutInventingExpiry() {
        val sent = Instant.parse("2026-10-22T00:00:00Z").toEpochMilli(); val zone = ZoneId.of("UTC")
        val mac = Port().sleeping.copy(availability = MacAvailability(MacPhase.ASLEEP, sent - 60_000))
        val early = MacRouting.waiting(mac, sent, sent + MacRouting.EXPIRY_SHOWN - 1, zone, Locale.US)!!
        assertTrue(early.contains("since yesterday")); assertTrue(early.endsWith("It starts when it wakes.")); assertFalse(early.contains("Expires"))
        val warning = MacRouting.waiting(mac, sent, sent + MacRouting.EXPIRY_SHOWN, zone, Locale.US)!!
        // CLDR puts a narrow no-break space (U+202F) between time and AM/PM;
        // older JDKs used a plain space. Devices use U+202F too. Normalize
        // before asserting so the test does not pin one JDK's CLDR version.
        assertTrue(warning.replace('\u202F', ' ').endsWith("Expires at 12:00 PM if it’s still asleep."))
        assertTrue(MacRouting.waiting(mac, sent, sent + MacRouting.LIFETIME + 1, zone, Locale.US)!!.contains("Expires at"))
        assertTrue(MacRouting.waiting(mac.copy(availability = MacAvailability(MacPhase.CLOSED)), sent, sent + MacRouting.EXPIRY_SHOWN, zone, Locale.US)!!.endsWith("still closed."))
        assertTrue(MacRouting.waiting(mac.copy(availability = MacAvailability(MacPhase.SILENT)), sent, sent + MacRouting.EXPIRY_SHOWN, zone, Locale.US)!!.endsWith("still away."))
        assertNull(MacRouting.waiting(mac.copy(availability = MacAvailability(MacPhase.UP)), sent, sent + MacRouting.EXPIRY_SHOWN, zone, Locale.US))
    }
}
