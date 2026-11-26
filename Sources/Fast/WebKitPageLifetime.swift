import WebKit

extension PageView {
    func retire(call: Bool, pictureInPicture wasPictureInPicture: Bool) {
        ClientCertificates.cancel(in: self)
        let web = self
        stateEvents = nil
        // An animation or a retained view may outlive its tab. Stop playback
        // now, before dropping delegates and removing it from the window.
        // The system's Picture-in-Picture window goes with it.
        web.setAllMediaPlaybackSuspended(true, completionHandler: {})
        if wasPictureInPicture { web.closeAllMediaPresentations(completionHandler: {}) }
        OpenTrace.mark("build.relays")
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.removeAllUserScripts()
        PageScripts.forget(controller)
        web.onPull = nil
        web.fromTitle = nil
        web.onFrom = nil
        web.canBackToSource = nil
        web.onStep = nil
        web.onHistory = nil
        web.onTouch = nil
        web.onSearch = nil
        web.onSelectedURL = nil
        web.searchName = nil
        web.onMeasure = nil
        web.onWebInspect = nil
        web.onImage = nil
        web.onMedia = nil
        web.mediaHeard = nil
        web.onPictureWords = nil
        web.onPictureCopied = nil
        web.onMailLink = nil
        web.onSplitLink = nil
        web.onPrivateLink = nil
        web.onHideAt = nil
        web.onCapture = nil
        web.onSelectionCommand = nil
        web.onSelectionMenu = nil
        web.onTranslationMenu = nil
        web.onAppleCodeContext = nil
        web.onAppleCodeOpen = nil
        web.onSelectionPause = nil
        web.onForceClick = nil
        web.onPress = nil
        web.stopLoading()
        web.events = nil
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
        Farewell.see(web, call: call)
    }
}
