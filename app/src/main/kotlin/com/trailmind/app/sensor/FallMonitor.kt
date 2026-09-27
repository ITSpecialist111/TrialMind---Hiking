package com.trailmind.app.sensor

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import com.trailmind.core.frontier.DetectedFall
import com.trailmind.core.frontier.FallDetector
import com.trailmind.core.frontier.ImuSample

class FallMonitor(
    context: Context,
    private val onFallDetected: (DetectedFall) -> Unit,
) : SensorEventListener {
    private val sensorManager = context.getSystemService(SensorManager::class.java)
    private val accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gyroscope = sensorManager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val pressure = sensorManager?.getDefaultSensor(Sensor.TYPE_PRESSURE)
    private val detector = FallDetector()
    private val gyro = FloatArray(3)
    private var altitudeMeters: Float? = null
    private var active = false
    private var thread: HandlerThread? = null

    val available get() = accelerometer != null && gyroscope != null

    @Synchronized
    fun setActive(enabled: Boolean) {
        if (enabled == active || enabled && !available) return
        active = enabled
        if (!enabled) {
            sensorManager?.unregisterListener(this)
            detector.reset()
            thread?.quitSafely()
            thread = null
            return
        }
        val sensorThread = HandlerThread("fall-monitor").apply { start() }
        thread = sensorThread
        val handler = Handler(sensorThread.looper)
        sensorManager?.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_GAME, handler)
        sensorManager?.registerListener(this, gyroscope, SensorManager.SENSOR_DELAY_GAME, handler)
        pressure?.let { sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL, handler) }
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_GYROSCOPE -> event.values.copyInto(gyro, endIndex = 3)
            Sensor.TYPE_PRESSURE -> altitudeMeters = SensorManager.getAltitude(
                SensorManager.PRESSURE_STANDARD_ATMOSPHERE,
                event.values[0],
            )
            Sensor.TYPE_ACCELEROMETER -> detector.add(
                ImuSample(
                    timestampMs = event.timestamp / 1_000_000,
                    accelerationX = event.values[0],
                    accelerationY = event.values[1],
                    accelerationZ = event.values[2],
                    gyroscopeX = gyro[0],
                    gyroscopeY = gyro[1],
                    gyroscopeZ = gyro[2],
                    altitudeMeters = altitudeMeters,
                ),
            )?.let(onFallDetected)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit
}
