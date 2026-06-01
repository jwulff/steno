import Testing
import Foundation
@testable import StenoDaemon

@Suite("DiarizationTierController")
struct DiarizationTierControllerTests {

    @Test func startsOnSortformer() async {
        let controller = DiarizationTierController()
        #expect(await controller.currentModel() == .sortformer)
        #expect(await controller.isEscalated == false)
    }

    @Test func staysOnSortformerWithinCap() async {
        let controller = DiarizationTierController()

        await controller.observe(speakerCount: 3)
        await controller.observe(speakerCount: 4)  // at the cap, not over

        #expect(await controller.currentModel() == .sortformer)
    }

    @Test func escalatesWhenSpeakerCountExceedsCap() async {
        let controller = DiarizationTierController()

        await controller.observe(speakerCount: 5)

        #expect(await controller.currentModel() == .lsEEND)
        #expect(await controller.isEscalated)
    }

    @Test func escalationIsStickyAcrossLowerCounts() async {
        let controller = DiarizationTierController()

        await controller.observe(speakerCount: 6)  // escalate
        await controller.observe(speakerCount: 1)  // would-be de-escalation

        #expect(await controller.currentModel() == .lsEEND)
    }

    @Test func respectsCustomThreshold() async {
        let controller = DiarizationTierController(escalationThreshold: 2)

        await controller.observe(speakerCount: 2)
        #expect(await controller.currentModel() == .sortformer)

        await controller.observe(speakerCount: 3)
        #expect(await controller.currentModel() == .lsEEND)
    }
}
