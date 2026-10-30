package com.star.desktop.domain

import com.star.proto.Config
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * P9: the profile chips and the limits behind Custom, against the daemon's side of the contract (`ExpertConfigFieldsTests`: limits clamped
 * to the same ranges; a switch to Custom that sends none takes the previous profile's).
 */
class ResourceProfilesTest {
    private fun configWithLimits(profile: String?) = Config.newBuilder().apply {
        if (profile != null) resourceProfile = profile
        customCpuWidth = 8; customQos = "utility"; customGpuWidth = 4; customGpuDutyCycle = 0.5
        customDiskStreamsPerVolume = 3; customIoPolicy = "throttle"
    }.build()

    @Test fun theChipsAreTheGuisInOrder() {
        assertEquals(listOf("full", "balanced", "light", "custom"), ResourceProfiles.choices.map { it.first })
        assertEquals(listOf("ui.use_full", "ui.use_balanced", "ui.use_light", "ui.use_custom"), ResourceProfiles.choices.map { it.second })
    }

    @Test fun aConfigThatNamesNoProfileIsFull() {
        assertEquals("full", ResourceProfiles.profileOf(null))
        assertEquals("full", ResourceProfiles.profileOf(Config.getDefaultInstance()))
        assertEquals("light", ResourceProfiles.profileOf(Config.newBuilder().setResourceProfile("light").build()))
    }

    /** The daemon starts Custom from the profile it leaves only when asked, since what this copy holds is what the limits last were. */
    @Test fun openingCustomFromAnotherProfileAsksForTheLimitsOfTheProfileItLeaves() {
        val sent = ResourceProfiles.switchTo(configWithLimits("light"), "custom")
        assertEquals("custom", sent.resourceProfile)
        assertTrue(sent.hasStartCustomFromProfile() && sent.startCustomFromProfile)
        // a config that says nothing of its profile is Full
        assertTrue(ResourceProfiles.switchTo(configWithLimits(null), "custom").startCustomFromProfile)
    }

    @Test fun otherSwitchesLeaveTheLimitsAlone() {
        val toBalanced = ResourceProfiles.switchTo(configWithLimits("light"), "balanced")
        assertEquals("balanced", toBalanced.resourceProfile)
        assertTrue(toBalanced.hasCustomCpuWidth(), "leaving Custom keeps what was set")
        assertFalse(toBalanced.hasStartCustomFromProfile())
        val stillCustom = ResourceProfiles.switchTo(configWithLimits("custom"), "custom")
        assertEquals(8, stillCustom.customCpuWidth)
        assertFalse(stillCustom.hasStartCustomFromProfile(), "already custom: nothing to take over")
    }

    @Test fun theLimitsAreReadBackAsTheDaemonSentThem() {
        val l = CustomLimits.of(configWithLimits("custom").toBuilder().setNumberOfFramesToProcessConcurrently(12).setMaxMatMemoryFraction(0.6).build())
        assertEquals(CustomLimits(12, 0.6, 8, 4, 0.5, 3, "utility", "throttle"), l)
    }

    @Test fun anEditIsHeldToTheRangesTheDaemonClampsTo() {
        val wild = CustomLimits(5000, 2.0, 0, 99, 0.0, 40, "background", "default")
        val sent = wild.applyTo(Config.getDefaultInstance())
        assertEquals(1024, sent.numberOfFramesToProcessConcurrently)
        assertEquals(0.95, sent.maxMatMemoryFraction, 1e-12)
        assertEquals(1, sent.customCpuWidth)
        assertEquals(32, sent.customGpuWidth)
        assertEquals(0.05, sent.customGpuDutyCycle, 1e-12)
        assertEquals(16, sent.customDiskStreamsPerVolume)
        assertEquals("background", sent.customQos)
        assertEquals("default", sent.customIoPolicy)
    }

    @Test fun everyNameHasAnEntryInTheCatalogue() {
        val names = CustomLimits.QOS.map { it.second } + CustomLimits.IO_POLICY.map { it.second }
        for (key in names) assertTrue(com.star.desktop.i18n.localized(key) != key, key)
        assertEquals(listOf("userInitiated", "utility", "background"), CustomLimits.QOS.map { it.first })
        assertEquals(listOf("default", "utility", "throttle"), CustomLimits.IO_POLICY.map { it.first })
    }
}
