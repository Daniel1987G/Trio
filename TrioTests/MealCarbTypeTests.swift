import Foundation
import Testing
@testable import Trio

@Suite("Meal Carb Type") struct MealCarbTypeTests {
    @Test("FPU table: 1 → 3 h, 2 → 4 h, 3 → 5 h, ≥ 4 → 7.5 h") func durations() {
        #expect(MealCarbType.extendedMinutes(forFPU: 1) == 180)
        #expect(MealCarbType.extendedMinutes(forFPU: 2) == 240)
        #expect(MealCarbType.extendedMinutes(forFPU: 3) == 300)
        #expect(MealCarbType.extendedMinutes(forFPU: 4) == 450)
        #expect(MealCarbType.extendedMinutes(forFPU: 6) == 450)
        #expect(MealCarbType.extendedMinutes(forFPU: Decimal(string: "0.5")!) == 180)
        #expect(MealCarbType.extendedMinutes(forFPU: Decimal(string: "2.5")!) == 300)
    }

    @Test("Pizza: 4 FPU, 1.5 U per carb unit → 6 U full, 3 U at 50 %") func pizza() {
        // 1.5 U per 10 g carbs is a carb ratio of 10 / 1.5 g/U
        let carbRatio = Decimal(10) / Decimal(string: "1.5")!
        let full = MealCarbType.fpuInsulin(fpu: 4, carbRatio: carbRatio, percent: 100)
        let half = MealCarbType.fpuInsulin(fpu: 4, carbRatio: carbRatio, percent: 50)
        #expect(abs(NSDecimalNumber(decimal: full).doubleValue - 6) < 0.0001)
        #expect(abs(NSDecimalNumber(decimal: half).doubleValue - 3) < 0.0001)
    }

    @Test("Exact FPU insulin and guards") func fpuInsulin() {
        // carb ratio 5 g/U = 2 U per carb unit
        #expect(MealCarbType.fpuInsulin(fpu: 4, carbRatio: 5, percent: 50) == 4)
        #expect(MealCarbType.fpuInsulin(fpu: 0, carbRatio: 5, percent: 50) == 0)
        #expect(MealCarbType.fpuInsulin(fpu: 4, carbRatio: 0, percent: 50) == 0)
    }

    @Test("FPU from fat and protein") func fpuFromNutrients() {
        // 30 g fat (270 kcal) + 20 g protein (80 kcal) = 350 kcal = 3.5 FPU
        #expect(MealCarbType.fpu(fat: 30, protein: 20) == 3.5)
        #expect(MealCarbType.fpu(fat: 0, protein: 0) == 0)
        #expect(MealCarbType.fpu(fat: 0, protein: 25) == 1)
    }

    @Test("Strategies per type") func strategies() {
        #expect(!MealCarbType.fast.usesExtendedBolus)
        #expect(!MealCarbType.medium.usesExtendedBolus)
        #expect(MealCarbType.slow.usesExtendedBolus && !MealCarbType.slow.coversFPU)
        #expect(MealCarbType.fatProteinRich.coversFPU)
        #expect(MealCarbType.fatProteinOnly.coversFPU)
        #expect(MealCarbType.slowImmediatePercent == 70)
    }

    @Test("FPU rounded to half units") func roundedToHalf() {
        #expect(Decimal(string: "4.61")!.roundedToHalf == Decimal(string: "4.5")!)
        #expect(Decimal(string: "4.8")!.roundedToHalf == 5)
        #expect(Decimal(string: "0.2")!.roundedToHalf == 0)
    }
}
