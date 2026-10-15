import Testing
@testable import OspreyEngine

@Suite struct RampControllerTests {
    @Test func startsWithOneConnection() {
        let ramp = RampController(maxConnections: 8, now: 0)
        #expect(ramp.allowed == 1)
    }

    @Test func doublesAtMostOncePerSecondWhileAllConnectionsReceive() {
        var ramp = RampController(maxConnections: 6, now: 0)
        #expect(ramp.update(now: 0.5, active: 1, productive: 1) == 1)
        #expect(ramp.update(now: 1.0, active: 1, productive: 1) == 2)
        #expect(ramp.update(now: 1.5, active: 2, productive: 2) == 2)
        #expect(ramp.update(now: 2.0, active: 2, productive: 1) == 2)   // one still connecting
        #expect(ramp.update(now: 2.1, active: 2, productive: 2) == 4)
        #expect(ramp.update(now: 3.2, active: 4, productive: 4) == 6)   // capped
        #expect(ramp.update(now: 9.0, active: 6, productive: 6) == 6)
    }

    @Test func limiterBrakeHoldsTheRamp() {
        var ramp = RampController(maxConnections: 8, now: 0)
        #expect(ramp.update(now: 5, active: 1, productive: 1, limiterBrake: true) == 1)
    }

    @Test func capLowersTheCeilingAndTheCurrentAllowance() {
        var ramp = RampController(maxConnections: 8, now: 0)
        ramp.update(now: 1, active: 1, productive: 1)
        ramp.update(now: 2, active: 2, productive: 2)
        #expect(ramp.allowed == 4)
        ramp.cap(at: 2)
        #expect(ramp.ceiling == 2)
        #expect(ramp.allowed == 2)
        #expect(ramp.update(now: 5, active: 2, productive: 2) == 2)     // never ramps past the cap
    }

    @Test func capBelowTheAllowanceKeepsRampingUpToIt() {
        var ramp = RampController(maxConnections: 8, now: 0)
        ramp.cap(at: 3)
        #expect(ramp.allowed == 1)
        #expect(ramp.update(now: 1, active: 1, productive: 1) == 2)
        #expect(ramp.update(now: 2, active: 2, productive: 2) == 3)
        #expect(ramp.update(now: 3, active: 3, productive: 3) == 3)
    }

    @Test func capIsClampedToOneAndTheMaximum() {
        var ramp = RampController(maxConnections: 4, now: 0)
        ramp.cap(at: 0)
        #expect(ramp.ceiling == 1)
        ramp.cap(at: 99)
        #expect(ramp.ceiling == 4)
    }

    @Test func uncapRestoresTheCeilingAndRampsAgain() {
        var ramp = RampController(maxConnections: 8, now: 0)
        #expect(ramp.update(now: 1, active: 1, productive: 1) == 2)
        ramp.cap(at: 1)
        #expect(ramp.update(now: 2, active: 1, productive: 1) == 1)
        ramp.uncap()
        #expect(ramp.ceiling == 8)
        #expect(ramp.allowed == 1)                     // ramps up again from where it is, not in one jump
        #expect(ramp.update(now: 3, active: 1, productive: 1) == 2)
        #expect(ramp.update(now: 4, active: 2, productive: 2) == 4)
    }

    @Test func singleConnectionModeNeverRamps() {
        var ramp = RampController(maxConnections: 1, now: 0)
        #expect(ramp.update(now: 10, active: 1, productive: 1) == 1)
    }
}

@Suite struct SpeedMeterTests {
    @Test func averagesOverTheWindow() {
        var meter = SpeedMeter(window: 3, startedAt: 0)
        for t in stride(from: 0.5, through: 3.0, by: 0.5) { meter.add(1_000, at: t) }
        #expect(meter.bytesPerSecond(at: 3.0) == 2_000)
        #expect(abs(meter.bytesPerSecond(at: 4.0) - 4_000.0 / 3.0) < 0.001)
    }

    @Test func usesElapsedTimeBeforeTheWindowFills() {
        var meter = SpeedMeter(window: 3, startedAt: 0)
        meter.add(1_000, at: 0.5)
        meter.add(1_000, at: 1.0)
        #expect(meter.bytesPerSecond(at: 1.0) == 2_000)
        #expect(meter.windowStats(at: 1.0).bytes == 2_000)
    }

    @Test func zeroWithoutData() {
        let meter = SpeedMeter(window: 3, startedAt: 0)
        #expect(meter.bytesPerSecond(at: 2) == 0)
    }
}

@Suite struct SpeedLimiterTests {
    @Test func pausesOnlyWhenOverTheLimit() {
        #expect(SpeedLimiter.pause(bytes: 900, elapsed: 1, limit: 1_000, currentSpeed: 900) == 0)
        #expect(SpeedLimiter.pause(bytes: 3_000, elapsed: 1, limit: 1_000, currentSpeed: 1_000) == 2)
    }

    @Test func dampsByCurrentSpeed() {
        #expect(SpeedLimiter.pause(bytes: 3_000, elapsed: 1, limit: 1_000, currentSpeed: 600) == 1)
        #expect(abs(SpeedLimiter.pause(bytes: 3_000, elapsed: 1, limit: 1_000, currentSpeed: 100) - 0.1) < 0.0001)
    }

    @Test func capsAtTwelveSeconds() {
        #expect(SpeedLimiter.pause(bytes: 100_000, elapsed: 1, limit: 1_000, currentSpeed: 5_000) == 12)
    }

    @Test func rampBrakeAtEightyFivePercent() {
        #expect(SpeedLimiter.allowsRamp(peakSpeed: 840, limit: 1_000))
        #expect(!SpeedLimiter.allowsRamp(peakSpeed: 850, limit: 1_000))
        #expect(SpeedLimiter.allowsRamp(peakSpeed: 1e9, limit: nil))
    }
}

@Suite struct RetryPolicyTests {
    @Test func linearBackOffCappedAtThirty() {
        let policy = RetryPolicy()
        #expect(policy.delay(afterAttempt: 1) == 2)
        #expect(policy.delay(afterAttempt: 5) == 10)
        #expect(policy.delay(afterAttempt: 20) == 30)
    }

    @Test func honoursRetryAfterWithinFiveMinutes() {
        let policy = RetryPolicy()
        #expect(policy.delay(afterAttempt: 1, retryAfter: 45) == 45)
        #expect(policy.delay(afterAttempt: 1, retryAfter: 1_000) == 300)
    }

    @Test func boundedAttempts() {
        #expect(RetryPolicy().canRetry(attempt: 19))
        #expect(!RetryPolicy().canRetry(attempt: 20))
        #expect(RetryPolicy(maxAttempts: nil).canRetry(attempt: 10_000))
    }
}
