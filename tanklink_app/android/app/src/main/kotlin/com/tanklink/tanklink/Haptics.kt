package com.tanklink.tanklink

import android.content.Context
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * lib/util/haptics.dart: named feedback patterns. Rich patterns are built
 * from the vibrator's primitives (Android 11+ phones with a good motor);
 * otherwise from the predefined effects, or a short pulse. Played as touch
 * feedback, so Android 13+ silences them when "Touch feedback" is off.
 */
object Haptics {
    private data class P(val id: Int, val scale: Float, val delayMs: Int = 0)

    private fun vibrator(c: Context): Vibrator =
        if (Build.VERSION.SDK_INT >= 31) {
            (c.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            c.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

    /** [scale] 0..1 strengthens or softens the pattern (the slider's detents). */
    fun play(c: Context, name: String, scale: Float) {
        val v = vibrator(c)
        if (!v.hasVibrator()) return
        val s = scale.coerceIn(0.05f, 1f)
        val effect = composed(v, name, s) ?: predefined(name) ?: oneShot(v, name, s)
        if (Build.VERSION.SDK_INT >= 33) {
            v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
        } else {
            @Suppress("DEPRECATION")
            v.vibrate(
                effect,
                android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .build(),
            )
        }
    }

    private fun primitives(name: String, s: Float): List<P>? {
        if (Build.VERSION.SDK_INT < 30) return null
        val click = VibrationEffect.Composition.PRIMITIVE_CLICK
        val tick = VibrationEffect.Composition.PRIMITIVE_TICK
        val thud = VibrationEffect.Composition.PRIMITIVE_THUD
        val spin = VibrationEffect.Composition.PRIMITIVE_SPIN
        val quickRise = VibrationEffect.Composition.PRIMITIVE_QUICK_RISE
        val slowRise = VibrationEffect.Composition.PRIMITIVE_SLOW_RISE
        val quickFall = VibrationEffect.Composition.PRIMITIVE_QUICK_FALL
        val lowTick = if (Build.VERSION.SDK_INT >= 31) VibrationEffect.Composition.PRIMITIVE_LOW_TICK else tick
        return when (name) {
            "tick" -> listOf(P(tick, 0.5f * s))
            "tap" -> listOf(P(click, 0.55f * s))
            "select" -> listOf(P(tick, 0.85f * s))
            "toggleOn" -> listOf(P(quickRise, 0.35f), P(click, 0.8f, 10))
            "toggleOff" -> listOf(P(click, 0.5f), P(lowTick, 0.6f, 30))
            "detent" -> listOf(P(tick, 0.25f + 0.75f * s))
            "grab" -> listOf(P(lowTick, 0.7f), P(click, 0.35f, 20))
            "release" -> listOf(P(quickFall, 0.45f))
            "confirm" -> listOf(P(click, 1f), P(thud, 0.6f, 30))
            "pumpStart" -> listOf(P(slowRise, 0.7f), P(thud, 1f, 40), P(click, 0.6f, 120))
            "pumpStop" -> listOf(P(quickFall, 0.9f), P(lowTick, 0.6f, 80), P(lowTick, 0.35f, 90))
            "success" -> listOf(P(click, 0.7f), P(click, 1f, 90))
            "warning" -> listOf(P(quickRise, 0.8f), P(thud, 0.9f, 30))
            "error" -> listOf(P(click, 1f), P(click, 1f, 90), P(thud, 1f, 90))
            "longPress" -> listOf(P(thud, 0.7f))
            "tankFull" -> listOf(P(spin, 0.5f), P(click, 0.8f, 60), P(click, 1f, 110))
            "connected" -> listOf(P(tick, 0.5f), P(click, 0.7f, 70))
            else -> null
        }
    }

    private fun composed(v: Vibrator, name: String, s: Float): VibrationEffect? {
        val parts = primitives(name, s) ?: return null
        if (Build.VERSION.SDK_INT < 30) return null
        if (!v.areAllPrimitivesSupported(*parts.map { it.id }.distinct().toIntArray())) return null
        val c = VibrationEffect.startComposition()
        for (p in parts) c.addPrimitive(p.id, p.scale.coerceIn(0f, 1f), p.delayMs)
        return c.compose()
    }

    private fun predefined(name: String): VibrationEffect? {
        if (Build.VERSION.SDK_INT < 29) return null
        val id = when (name) {
            "tick", "select", "detent", "release", "toggleOff" -> VibrationEffect.EFFECT_TICK
            "tap", "toggleOn", "grab", "connected" -> VibrationEffect.EFFECT_CLICK
            "confirm", "longPress", "warning", "pumpStart" -> VibrationEffect.EFFECT_HEAVY_CLICK
            "success", "pumpStop", "tankFull", "error" -> VibrationEffect.EFFECT_DOUBLE_CLICK
            else -> return null
        }
        return VibrationEffect.createPredefined(id)
    }

    private fun oneShot(v: Vibrator, name: String, s: Float): VibrationEffect {
        val ms = when (name) {
            "confirm", "pumpStart", "error", "warning", "longPress" -> 40L
            "tap", "toggleOn", "success", "pumpStop", "tankFull", "connected", "grab" -> 20L
            else -> 10L
        }
        val amp = if (v.hasAmplitudeControl()) (255 * s).toInt().coerceIn(1, 255) else VibrationEffect.DEFAULT_AMPLITUDE
        return VibrationEffect.createOneShot(ms, amp)
    }
}
