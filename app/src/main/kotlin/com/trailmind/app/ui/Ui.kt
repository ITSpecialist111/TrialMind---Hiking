package com.trailmind.app.ui

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.InputType
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast

/** Colour palette, resolved for day/night. */
class Palette(val night: Boolean) {
    val bg = if (night) 0xFF101512.toInt() else 0xFFF4F6F2.toInt()
    val surface = if (night) 0xFF1A211D.toInt() else 0xFFFFFFFF.toInt()
    val surfaceVariant = if (night) 0xFF25302A.toInt() else 0xFFE6EDE7.toInt()
    val onSurface = if (night) 0xFFE6ECE8.toInt() else 0xFF17201B.toInt()
    val muted = if (night) 0xFFA3B1A9.toInt() else 0xFF5B6A61.toInt()
    val primary = if (night) 0xFF7FD1AE.toInt() else 0xFF1F5B45.toInt()
    val onPrimary = if (night) 0xFF06281B.toInt() else 0xFFFFFFFF.toInt()
    val primaryContainer = if (night) 0xFF1E4A38.toInt() else 0xFFCDEBDC.toInt()
    val onPrimaryContainer = if (night) 0xFFCDEBDC.toInt() else 0xFF0B3325.toInt()
    val accent = if (night) 0xFFFFB066.toInt() else 0xFFE07A12.toInt()
    val danger = if (night) 0xFFFF8A80.toInt() else 0xFFC62828.toInt()
    val dangerContainer = if (night) 0xFF5C1B17.toInt() else 0xFFFDE2DF.toInt()
    val warnContainer = if (night) 0xFF4A3A12.toInt() else 0xFFFFF1CC.toInt()
    val outline = if (night) 0xFF3A463F.toInt() else 0xFFD3DBD5.toInt()
    val route = 0xFF8E24AA.toInt()
    val track = 0xFFF06E14.toInt()

    companion object {
        fun of(ctx: Context) = Palette(
            (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES,
        )
    }
}

fun Context.dp(v: Number): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()
fun View.dp(v: Number): Int = context.dp(v)

fun Context.toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

/** Non-breaking spaces, so a value such as "2h 25m" or "↑800 m" never wraps in the middle. */
fun nb(s: String) = s.replace(' ', '\u00A0')

fun rounded(color: Int, radiusPx: Float, strokeColor: Int? = null, strokePx: Int = 0) = GradientDrawable().apply {
    setColor(color)
    cornerRadius = radiusPx
    if (strokeColor != null) setStroke(strokePx, strokeColor)
}

fun ripple(content: Drawable?, rippleColor: Int, mask: Drawable? = null) =
    RippleDrawable(ColorStateList.valueOf(rippleColor), content, mask ?: content ?: rounded(Color.WHITE, 0f))

/** Lays children out left to right and wraps onto new lines, so no chip or button is ever pushed off-screen. */
@SuppressLint("ViewConstructor")
class FlowLayout(ctx: Context, private val gapPx: Int) : ViewGroup(ctx) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = MeasureSpec.getSize(widthMeasureSpec)
        val maxW = if (MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED) Int.MAX_VALUE else size - paddingLeft - paddingRight
        val childW = MeasureSpec.makeMeasureSpec(if (maxW == Int.MAX_VALUE) 0 else maxW, if (maxW == Int.MAX_VALUE) MeasureSpec.UNSPECIFIED else MeasureSpec.AT_MOST)
        var x = 0; var y = 0; var rowH = 0; var widest = 0
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            if (c.visibility == GONE) continue
            c.measure(childW, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            if (x > 0 && x + c.measuredWidth > maxW) { x = 0; y += rowH + gapPx; rowH = 0 }
            x += c.measuredWidth + gapPx
            rowH = maxOf(rowH, c.measuredHeight)
            widest = maxOf(widest, x - gapPx)
        }
        setMeasuredDimension(resolveSize(widest + paddingLeft + paddingRight, widthMeasureSpec),
            resolveSize(y + rowH + paddingTop + paddingBottom, heightMeasureSpec))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val maxW = r - l - paddingLeft - paddingRight
        var x = 0; var y = 0; var rowH = 0
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            if (c.visibility == GONE) continue
            if (x > 0 && x + c.measuredWidth > maxW) { x = 0; y += rowH + gapPx; rowH = 0 }
            c.layout(paddingLeft + x, paddingTop + y, paddingLeft + x + c.measuredWidth, paddingTop + y + c.measuredHeight)
            x += c.measuredWidth + gapPx
            rowH = maxOf(rowH, c.measuredHeight)
        }
    }
}

/** Small declarative helpers so pages read clearly without XML layouts. */
class Ui(val ctx: Context) {
    val p = Palette.of(ctx)
    fun dp(v: Number) = ctx.dp(v)

    fun lp(w: Int = ViewGroup.LayoutParams.MATCH_PARENT, h: Int = ViewGroup.LayoutParams.WRAP_CONTENT, weight: Float = 0f) =
        LinearLayout.LayoutParams(w, h, weight)

    fun column(padding: Int = 0, spacing: Int = 0, block: LinearLayout.() -> Unit = {}): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
        if (spacing > 0) {
            showDividers = LinearLayout.SHOW_DIVIDER_MIDDLE
            dividerDrawable = GradientDrawable().apply { setSize(0, dp(spacing)); setColor(Color.TRANSPARENT) }
        }
        block()
    }

    fun row(spacing: Int = 8, gravity: Int = Gravity.CENTER_VERTICAL, block: LinearLayout.() -> Unit = {}): LinearLayout = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        this.gravity = gravity
        if (spacing > 0) {
            showDividers = LinearLayout.SHOW_DIVIDER_MIDDLE
            dividerDrawable = GradientDrawable().apply { setSize(dp(spacing), 0); setColor(Color.TRANSPARENT) }
        }
        block()
    }

    fun scroll(content: View): ScrollView = ScrollView(ctx).apply {
        isFillViewport = true
        clipToPadding = false
        addView(content, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    fun flow(spacing: Int = 8, block: FlowLayout.() -> Unit = {}): FlowLayout = FlowLayout(ctx, dp(spacing)).apply(block)

    enum class T { DISPLAY, TITLE, HEADLINE, BODY, LABEL, CAPTION, MONO }

    fun text(s: CharSequence, style: T = T.BODY, color: Int = if (style == T.CAPTION || style == T.LABEL) p.muted else p.onSurface): TextView =
        TextView(ctx).apply {
            text = s
            setTextColor(color)
            when (style) {
                T.DISPLAY -> { textSize = 34f; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) }
                T.HEADLINE -> { textSize = 24f; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) }
                T.TITLE -> { textSize = 17f; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) }
                T.BODY -> { textSize = 15f; setLineSpacing(0f, 1.15f) }
                T.LABEL -> { textSize = 12f; isAllCaps = true; letterSpacing = 0.06f; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) }
                T.CAPTION -> { textSize = 13f; setLineSpacing(0f, 1.1f) }
                T.MONO -> { textSize = 15f; typeface = Typeface.MONOSPACE }
            }
        }

    fun card(color: Int = p.surface, padding: Int = 16, spacing: Int = 8, block: LinearLayout.() -> Unit = {}): LinearLayout =
        column(padding, spacing, block).apply {
            background = rounded(color, dp(20).toFloat(), p.outline.takeIf { color == p.surface }, dp(1))
        }

    enum class B { FILLED, TONAL, OUTLINED, TEXT, DANGER }

    fun button(label: String, icon: Int? = null, style: B = B.FILLED, onClick: () -> Unit): TextView = TextView(ctx).apply {
        text = label
        textSize = 15f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        minHeight = dp(48)
        setPadding(dp(18), dp(10), dp(18), dp(10))
        val (bg, fg) = when (style) {
            B.FILLED -> p.primary to p.onPrimary
            B.TONAL -> p.primaryContainer to p.onPrimaryContainer
            B.OUTLINED -> Color.TRANSPARENT to p.primary
            B.TEXT -> Color.TRANSPARENT to p.primary
            B.DANGER -> p.danger to Color.WHITE
        }
        setTextColor(fg)
        val shape = rounded(bg, dp(24).toFloat(), if (style == B.OUTLINED) p.outline else null, dp(1))
        background = ripple(shape, (fg and 0x00FFFFFF) or 0x33000000, rounded(Color.WHITE, dp(24).toFloat()))
        if (icon != null) {
            val d = ctx.getDrawable(icon)?.mutate()
            d?.setTint(fg)
            d?.setBounds(0, 0, dp(20), dp(20))
            setCompoundDrawablesRelative(d, null, null, null)
            compoundDrawablePadding = dp(8)
        }
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
    }

    /** Round floating icon button for map controls. */
    fun fab(icon: Int, description: String, sizeDp: Int = 48, bg: Int = p.surface, fg: Int = p.onSurface, onClick: () -> Unit): ImageButton =
        ImageButton(ctx).apply {
            setImageDrawable(ctx.getDrawable(icon)?.mutate()?.apply { setTint(fg) })
            contentDescription = description
            scaleType = ImageView.ScaleType.CENTER
            val circle = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(bg) }
            background = ripple(circle, 0x33000000, GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) })
            elevation = dp(4).toFloat()
            layoutParams = LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp))
            setOnClickListener { onClick() }
        }

    fun chip(label: String, selected: Boolean = false, onClick: (() -> Unit)? = null): TextView = TextView(ctx).apply {
        text = label
        textSize = 13f
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(if (selected) p.onPrimaryContainer else p.onSurface)
        setPadding(dp(12), dp(7), dp(12), dp(7))
        background = rounded(if (selected) p.primaryContainer else p.surface, dp(16).toFloat(), p.outline, dp(1))
        if (onClick != null) { isClickable = true; setOnClickListener { onClick() } }
    }

    /** Label over a value; both shrink to fit a weighted column instead of being clipped. */
    fun stat(label: String, value: String, big: Boolean = false): LinearLayout = column {
        addView(text(label, T.LABEL).apply {
            maxLines = 1
            setAutoSizeTextTypeUniformWithConfiguration(8, 12, 1, TypedValue.COMPLEX_UNIT_SP)
        }, lp())
        addView(text(value, if (big) T.HEADLINE else T.TITLE).apply {
            maxLines = 1
            setAutoSizeTextTypeUniformWithConfiguration(10, if (big) 24 else 17, 1, TypedValue.COMPLEX_UNIT_SP)
        }, lp())
    }

    /** Grid of stat tiles, [cols] per row. */
    fun statGrid(items: List<Pair<String, String>>, cols: Int = 3): LinearLayout = column(spacing = 12) {
        items.chunked(cols).forEach { chunk ->
            addView(row(spacing = 12, gravity = Gravity.TOP) {
                chunk.forEach { (l, v) -> addView(stat(l, v), lp(0, weight = 1f)) }
                repeat(cols - chunk.size) { addView(View(ctx), lp(0, 1, 1f)) }
            })
        }
    }

    fun input(hint: String, value: String = "", type: Int = InputType.TYPE_CLASS_TEXT): EditText = EditText(ctx).apply {
        this.hint = hint
        setText(value)
        inputType = type
        setTextColor(p.onSurface)
        setHintTextColor(p.muted)
        textSize = 15f
        setSingleLine(type and InputType.TYPE_TEXT_FLAG_MULTI_LINE == 0)
        setPadding(dp(14), dp(12), dp(14), dp(12))
        background = rounded(p.surfaceVariant, dp(12).toFloat())
    }

    fun switch(label: String, checked: Boolean, onChange: (Boolean) -> Unit): Switch = Switch(ctx).apply {
        text = label
        textSize = 15f
        setTextColor(p.onSurface)
        isChecked = checked
        minHeight = dp(48)
        setOnCheckedChangeListener { _, v -> onChange(v) }
    }

    fun progress(max: Int = 1000): ProgressBar = ProgressBar(ctx, null, android.R.attr.progressBarStyleHorizontal).apply {
        this.max = max
        progressTintList = ColorStateList.valueOf(p.primary)
        progressBackgroundTintList = ColorStateList.valueOf(p.surfaceVariant)
    }

    fun divider(): View = View(ctx).apply {
        setBackgroundColor(p.outline)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1)
    }

    fun spacer(h: Int = 8): View = View(ctx).apply { layoutParams = LinearLayout.LayoutParams(1, dp(h)) }

    /** Tappable list row with title/subtitle and optional trailing badge. */
    fun listItem(title: String, subtitle: String?, icon: Int? = null, badge: String? = null, onClick: () -> Unit): LinearLayout =
        row(spacing = 14) {
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = ripple(rounded(p.surface, dp(18).toFloat(), p.outline, dp(1)), 0x22000000, rounded(Color.WHITE, dp(18).toFloat()))
            isClickable = true
            setOnClickListener { onClick() }
            if (icon != null) {
                addView(ImageView(ctx).apply {
                    setImageDrawable(ctx.getDrawable(icon)?.mutate()?.apply { setTint(p.primary) })
                    background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(p.primaryContainer) }
                    setPadding(dp(10), dp(10), dp(10), dp(10))
                }, LinearLayout.LayoutParams(dp(44), dp(44)))
            }
            addView(column {
                addView(text(title, T.TITLE).apply { maxLines = 2; ellipsize = TextUtils.TruncateAt.END })
                if (!subtitle.isNullOrBlank()) addView(text(subtitle, T.CAPTION))
            }, lp(0, weight = 1f))
            if (badge != null) addView(chip(badge, selected = true))
        }

    fun banner(message: String, danger: Boolean = false, icon: Int = com.trailmind.app.R.drawable.ic_warning): LinearLayout = row(spacing = 12) {
        setPadding(dp(14), dp(12), dp(14), dp(12))
        background = rounded(if (danger) p.dangerContainer else p.warnContainer, dp(16).toFloat())
        addView(ImageView(ctx).apply {
            setImageDrawable(ctx.getDrawable(icon)?.mutate()?.apply { setTint(if (danger) p.danger else p.accent) })
        }, LinearLayout.LayoutParams(dp(22), dp(22)))
        addView(text(message, T.CAPTION, p.onSurface), lp(0, weight = 1f))
    }

    /** Header used by every page: back arrow (optional) and title, with any actions on a wrapping row below it. */
    fun header(title: String, onBack: (() -> Unit)?, vararg actions: View): LinearLayout {
        val top = row(spacing = 4) {
            setPadding(dp(4), dp(8), dp(8), dp(4))
            if (onBack != null) {
                addView(ImageButton(ctx).apply {
                    setImageDrawable(ctx.getDrawable(com.trailmind.app.R.drawable.ic_arrow_back)?.mutate()?.apply { setTint(p.onSurface) })
                    contentDescription = "Back"
                    background = ripple(null, 0x22000000, GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) })
                    setOnClickListener { onBack() }
                }, LinearLayout.LayoutParams(dp(48), dp(48)))
            } else addView(View(ctx), LinearLayout.LayoutParams(dp(12), 1))
            addView(text(title, T.HEADLINE).apply { maxLines = 2; ellipsize = TextUtils.TruncateAt.END }, lp(0, weight = 1f))
        }
        if (actions.isEmpty()) return top
        return column {
            addView(top)
            addView(flow { setPadding(dp(16), 0, dp(12), dp(4)); actions.forEach { addView(it) } })
        }
    }

    fun dialog(): AlertDialog.Builder = AlertDialog.Builder(
        ctx,
        if (p.night) android.R.style.Theme_DeviceDefault_Dialog_Alert else android.R.style.Theme_DeviceDefault_Light_Dialog_Alert,
    )

    fun confirm(title: String, message: String, ok: String, danger: Boolean = false, onOk: () -> Unit) {
        dialog().setTitle(title).setMessage(message)
            .setPositiveButton(ok) { _, _ -> onOk() }
            .setNegativeButton("Cancel", null)
            .show()
    }

    fun prompt(title: String, initial: String, hint: String = "", type: Int = InputType.TYPE_CLASS_TEXT, onOk: (String) -> Unit) {
        val box = FrameLayout(ctx).apply { setPadding(dp(20), dp(8), dp(20), 0) }
        val e = input(hint, initial, type)
        box.addView(e)
        dialog().setTitle(title).setView(box)
            .setPositiveButton("OK") { _, _ -> onOk(e.text.toString().trim()) }
            .setNegativeButton("Cancel", null)
            .show()
    }
}
