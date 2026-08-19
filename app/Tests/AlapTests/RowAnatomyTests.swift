import Foundation
import Testing
@testable import Alap

/// The row's shape at each density.
///
/// Density is the direction's most falsifiable claim — "about 20 conversations
/// in a standard window" — so it gets a test rather than a screenshot.
struct RowAnatomyTests {
  @Test("Compact fits the stated number of conversations")
  func compactMeetsTheBar() {
    // The whole argument for density: at the old ~81pt row a 900pt window
    // showed NINE conversations, which is not enough context to triage a
    // 32,000-message mailbox against.
    let compact = RowAnatomy(.compact)

    #expect(compact.height == 44)
    #expect(compact.visibleRows(inListHeight: 880) >= 20)
  }

  @Test("Every density sits on the 4pt grid", arguments: ListDensity.allCases)
  func heightsAreOnGrid(density: ListDensity) {
    let anatomy = RowAnatomy(density)
    #expect(anatomy.height.truncatingRemainder(dividingBy: 4) == 0)
  }

  @Test("Heights are ordered and fixed", arguments: ListDensity.allCases)
  func heightIsDeterministic(density: ListDensity) {
    // Fixed per density, not emergent from content — which is what lets `List`
    // use a constant row height and is why the flag no longer makes one row
    // taller than its neighbours.
    #expect(RowAnatomy(density) == RowAnatomy(density))
  }

  @Test("Denser rows are shorter, in order")
  func densitiesAreOrdered() {
    #expect(RowAnatomy(.compact).height < RowAnatomy(.comfortable).height)
    #expect(RowAnatomy(.comfortable).height < RowAnatomy(.relaxed).height)
  }

  @Test("Only compact runs the subject and snippet together")
  func onlyCompactIsSingleLine() {
    // In compact the snippet runs on after the subject in one `Text`, so
    // truncation eats the snippet first. The other two give it its own lines.
    #expect(RowAnatomy(.compact).isSingleLine)
    #expect(RowAnatomy(.compact).snippetLines == 0)
    #expect(RowAnatomy(.comfortable).isSingleLine == false)
    #expect(RowAnatomy(.comfortable).snippetLines == 1)
    #expect(RowAnatomy(.relaxed).snippetLines == 2)
  }

  @Test("Comfortable is the default")
  func comfortableIsDefault() {
    // Decided by opening the running build against a real mailbox rather than
    // by argument: at this list's width compact truncates the subject to a
    // stub, and a row that tells you who wrote but not what about is not a
    // triage row. Comfortable still shows ~14 conversations against the old 9.
    #expect(ListDensity.standard == .comfortable)
    #expect(RowAnatomy(.standard).snippetLines == 1)
  }

  @Test("The densities are still offered densest-first")
  func orderingIsUnchanged() {
    // The picker reads as a scale, so the ORDER stays by density even though
    // the default is no longer the first entry.
    #expect(ListDensity.allCases == [.compact, .comfortable, .relaxed])
  }

  @Test("Density identifiers round-trip for persistence",
        arguments: ListDensity.allCases)
  func rawValuesRoundTrip(density: ListDensity) {
    // These land in UserDefaults, so renaming a case silently resets
    // everyone's choice.
    #expect(ListDensity(rawValue: density.rawValue) == density)
  }
}

/// The gutter's two controls, against WCAG 2.2 SC 2.5.8.
///
/// These are the most-struck controls in the app — once per row, on a list that
/// runs to five hundred — and they were the two furthest under the floor.
struct HitTargetTests {
  @Test("The gutter clears the 24pt target-size floor")
  func gutterMeetsTargetSize() {
    // SC 2.5.8 has a spacing exception, and it does not rescue these: at 20pt
    // and 18pt wide their centres sat 19pt apart, inside the 24 the exception
    // requires. So the size is the only route, and the gutter widens for it.
    #expect(Theme.Size.hitTarget >= 24)
  }

  @Test("Widening the gutter did not eat the row")
  func gutterStillFitsTheNarrowestList() {
    // The narrowest list `PaneLayout` allows is 300pt. Rail plus two targets
    // plus the leading inset must leave a content column that can still show a
    // sender and a subject — the thing the row exists for.
    let gutter = Theme.Space.tight + (Theme.Size.hitTarget * 2)
    let content = 300 - 2 - gutter - Theme.Space.tight - Theme.Space.loose

    #expect(gutter == 52)
    #expect(content >= 230, "content column collapsed to \(content)pt")
  }
}
