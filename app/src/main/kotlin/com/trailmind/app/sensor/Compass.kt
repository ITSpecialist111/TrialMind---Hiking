package com.trailmind.app.sensor

import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.view.Display
import android.view.Surface
import android.view.WindowManager
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/**
 * Heading from the rotation-vector sensor (fused accel/mag/gyro), falling back to accelerometer +
 * magnetometer. Corrects for screen rotation and magnetic declination (from the last GPS fix).
 * Accurate when the phone is held roughly flat.
 */
class Compass(private val context: Context, private val onHeading: (trueDeg: Double, magneticDeg: Double, accuracy: Int) -> Unit) :
    SensorEventListener {
    private val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val rotation = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private val accel = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val mag = sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)

    val available: Boolean get() = rotation != null || (accel != null && mag != null)
    var accuracy = SensorManager.SENSOR_STATUS_UNRELIABLE; private set
    var declinationDeg = 0.0; private set

    private val r = FloatArray(9)
    private val remapped = FloatArray(9)
    private val orient = FloatArray(3)
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
        declinationDeg = GeomagneticField(lat.toFloat(), lon.toFloat(), altM.toFloat(), System.currentTimeMillis()).declination.toDouble()
    }

    override fun onAccuracyChanged(sensor: Sensor, acc: Int) {
        if (sensor.type == Sensor.TYPE_MAGNETIC_FIELD || sensor.type == Sensor.TYPE_ROTATION_VECTOR) accuracy = acc
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR -> SensorManager.getRotationMatrixFromVector(r, event.values)
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
        SensorManager.getOrientation(remapped, orient)
        val az = orient[0].toDouble()
        if (!hasValue) { sinS = sin(az); cosS = cos(az); hasValue = true } else {
            val a = 0.15
            sinS += a * (sin(az) - sinS)
            cosS += a * (cos(az) - cosS)
        }
        val now = System.nanoTime()
        if (now - lastEmit < 33_000_000L) return
        lastEmit = now
        val magnetic = (Math.toDegrees(atan2(sinS, cosS)) + 360.0) % 360.0
        onHeading((magnetic + declinationDeg + 360.0) % 360.0, magnetic, accuracy)
    }

    private fun fromAccelMag(): Boolean {
        val g = gravity ?: return false
        val m = geomag ?: return false
        return SensorManager.getRotationMatrix(r, null, g, m)
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
}
