package com.trailmind.app.sensor

import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.WindowManager
import com.trailmind.core.geo.MagneticCheck
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/**
 * Heading from the rotation-vector sensor (fused accel/mag/gyro), falling back to accelerometer +
 * magnetometer. Corrects for screen rotation and magnetic declination (from the last GPS fix).
 * Works flat (the way the top edge points) and upright (the way the back of the phone faces).
 */
class Compass(
    private val context: Context,
    private val onHeading: (trueDeg: Double, magneticDeg: Double, accuracy: Int, disturbed: Boolean) -> Unit,
) : SensorEventListener {
    private val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val rotation = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private val accel = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val mag = sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)
    // The magnetometer's accuracy is its calibration state; a rotation vector's accuracy means different things per vendor.
    private val accuracySensor = mag ?: rotation

    val available: Boolean get() = rotation != null || (accel != null && mag != null)
    /** Calibration state; assumed good until the first reading, so the warning does not flash on start. */
    var accuracy = SensorManager.SENSOR_STATUS_ACCURACY_HIGH; private set
    var declinationDeg = 0.0; private set
    private val field = MagneticCheck()

    private val r = FloatArray(9)
    private var hasMatrix = false
    private val remapped = FloatArray(9)
    private var gravity: FloatArray? = null
    private var geomag: FloatArray? = null
    private var sinS = 0.0
    private var cosS = 0.0
    private var hasValue = false
    private var lastEmit = 0L
    private var running = false

    fun start() {
        if (running) return
        running = true
        hasValue = false
        hasMatrix = false
        field.reset()
        accuracy = SensorManager.SENSOR_STATUS_ACCURACY_HIGH
        if (rotation != null) {
            sm.registerListener(this, rotation, SensorManager.SENSOR_DELAY_UI)
            mag?.let { sm.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL) } // accuracy reports
        } else {
            accel?.let { sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI) }
            mag?.let { sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI) }
        }
    }

    fun stop() {
        if (!running) return
        running = false
        sm.unregisterListener(this)
    }

    fun updateLocation(lat: Double, lon: Double, altM: Double) {
        val g = GeomagneticField(lat.toFloat(), lon.toFloat(), altM.toFloat(), System.currentTimeMillis())
        declinationDeg = g.declination.toDouble()
        field.expect(g.fieldStrength / 1000.0, g.inclination.toDouble())
    }

    override fun onAccuracyChanged(sensor: Sensor, acc: Int) {
        if (sensor.type == accuracySensor?.type) setAccuracy(acc)
    }

    private fun setAccuracy(acc: Int) {
        if (acc == accuracy) return
        accuracy = acc
        Log.i(TAG, "accuracy $acc from ${accuracySensor?.name}")
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type == accuracySensor?.type) setAccuracy(event.accuracy)
        if (event.sensor.type == Sensor.TYPE_MAGNETIC_FIELD && hasMatrix) {
            val v = event.values
            val was = field.disturbed
            field.add(v[0].toDouble(), v[1].toDouble(), v[2].toDouble(), r[6].toDouble(), r[7].toDouble(), r[8].toDouble())
            if (field.disturbed != was) {
                Log.i(TAG, "interference ${field.disturbed}: %.1f µT dipping %.1f°".format(field.strengthUt, field.dipDeg))
            }
        }
        when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR -> { SensorManager.getRotationMatrixFromVector(r, event.values); hasMatrix = true }
            Sensor.TYPE_ACCELEROMETER -> { gravity = lowPass(event.values, gravity); if (!fromAccelMag()) return }
            Sensor.TYPE_MAGNETIC_FIELD -> {
                if (rotation != null) return
                geomag = lowPass(event.values, geomag); if (!fromAccelMag()) return
            }
            else -> return
        }
        val (ax, ay) = when (displayRotation()) {
            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
            else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
        }
        SensorManager.remapCoordinateSystem(r, ax, ay, remapped)
        // The horizontal line in the screen's up/back plane: east and north parts of (up x screen-right).
        val east = -remapped[3].toDouble()
        val north = remapped[0].toDouble()
        // Screen's right edge pointing straight up or down: no usable heading, keep the last one.
        if (east * east + north * north < 0.04) return
        val az = atan2(east, north)
        if (!hasValue) { sinS = sin(az); cosS = cos(az); hasValue = true } else {
            val a = 0.15
            sinS += a * (sin(az) - sinS)
            cosS += a * (cos(az) - cosS)
        }
        val now = System.nanoTime()
        if (now - lastEmit < 33_000_000L) return
        lastEmit = now
        val magnetic = (Math.toDegrees(atan2(sinS, cosS)) + 360.0) % 360.0
        onHeading((magnetic + declinationDeg + 360.0) % 360.0, magnetic, accuracy, field.disturbed)
    }

    private fun fromAccelMag(): Boolean {
        val g = gravity ?: return false
        val m = geomag ?: return false
        return SensorManager.getRotationMatrix(r, null, g, m).also { if (it) hasMatrix = true }
    }

    private fun lowPass(v: FloatArray, prev: FloatArray?): FloatArray {
        if (prev == null) return v.copyOf()
        for (i in 0 until 3) prev[i] += 0.2f * (v[i] - prev[i])
        return prev
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int {
        val d: Display? = if (Build.VERSION.SDK_INT >= 30) runCatching { context.display }.getOrNull()
        else (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay
        return d?.rotation ?: Surface.ROTATION_0
    }

    private companion object {
        const val TAG = "Compass"
    }
}
