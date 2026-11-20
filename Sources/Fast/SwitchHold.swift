/// A tab switch held until its page has drawn (Browser.select): which tab,
/// and which attempt. Each hold is a new attempt, so a finisher left from an
/// earlier one (A→B→A→B, its 80 ms timer still due) can't end a later hold
/// early and land the window's redraw on the page's first frame (#243).
struct SwitchHold: Equatable {
    private(set) var tab: Tab.ID?
    private(set) var attempt = 0

    mutating func hold(_ id: Tab.ID) -> Int {
        attempt &+= 1
        tab = id
        return attempt
    }

    mutating func release() { tab = nil }

    func holds(_ id: Tab.ID, attempt: Int) -> Bool { tab == id && self.attempt == attempt }
}
