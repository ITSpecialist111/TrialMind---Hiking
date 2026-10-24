package com.trailmind.app.ui

import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.InputType
import android.text.SpannableString
import android.text.Spanned
import android.text.TextUtils
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.TypefaceSpan
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
    val bg = if (night) 0xFF0C110F.toInt() else 0xFFEFF3EE.toInt()
    val surface = if (night) 0xFF161D19.toInt() else 0xFFFFFFFF.toInt()
    val surfaceVariant = if (night) 0xFF222C27.toInt() else 0xFFE3EAE4.toInt()
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

    // Translucent surfaces do not reduce the opacity of text or safety controls.
    val glass = if (night) 0xEC161D19.toInt() else 0xECFFFFFF.toInt()
    val glassStroke = if (night) 0x33FFFFFF else 0x16000000
    val inverse = if (night) 0xF8222C27.toInt() else 0xF816211B.toInt()
    val onInverse = 0xFFEAF2EC.toInt()
    val inverseMuted = 0xFFA3B5AA.toInt()
    val navSelected = if (night) 0xFF7FD1AE.toInt() else 0xFFBDF0D4.toInt()
    val onNavSelected = 0xFF0B2E21.toInt()

    companion object {
        fun of(ctx: Context) = Palette(
            (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES,
        )
    }
}

/** A figure and its unit ("360 m", "↑12 m", "14.8 km/h"); a value with more than one number in it is left whole. */
private val NUMBER_UNIT = Regex("""^([↑↓+\-]?\d[\d.,]*)[\s\u00A0]*([A-Za-z°%/²]+)$""")

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

    /** Paired actions stay on one row only when each label has its natural width. */
    fun actionRow(spacing: Int = 8, block: LinearLayout.() -> Unit): LinearLayout =
        object : LinearLayout(ctx) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val children = (0 until childCount).map { getChildAt(it) }.filter { it.visibility != GONE }
                val natural = children.map {
                    it.measure(MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
                        MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
                    it.measuredWidth
                }
                val available = MeasureSpec.getSize(widthMeasureSpec) - paddingLeft - paddingRight
                val fits = MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED ||
                    natural.sum() + dp(spacing) * (children.size - 1).coerceAtLeast(0) <= available
                val direction = if (fits) HORIZONTAL else VERTICAL
                if (orientation != direction) orientation = direction
                children.forEachIndexed { index, view ->
                    val params = view.layoutParams as LayoutParams
                    val width = if (fits) natural[index] else ViewGroup.LayoutParams.MATCH_PARENT
                    val weight = if (fits) 1f else 0f
                    if (params.width != width || params.weight != weight) {
                        params.width = width
                        params.weight = weight
                        view.layoutParams = params
                    }
                }
                super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            }
        }.apply {
            gravity = Gravity.CENTER_VERTICAL
            showDividers = LinearLayout.SHOW_DIVIDER_MIDDLE
            dividerDrawable = GradientDrawable().apply { setSize(dp(spacing), dp(spacing)); setColor(Color.TRANSPARENT) }
            block()
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

    /** An underlined caption that opens its source, for credits whose licence asks for a link. */
    fun link(label: CharSequence, onClick: () -> Unit): TextView = text(label, T.CAPTION, p.primary).apply {
        paintFlags = paintFlags or Paint.UNDERLINE_TEXT_FLAG
        gravity = Gravity.CENTER_VERTICAL
        minHeight = dp(48)
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
    }

    fun card(color: Int = p.surface, padding: Int = 16, spacing: Int = 8, block: LinearLayout.() -> Unit = {}): LinearLayout =
        column(padding, spacing, block).apply {
            // Borderless and tonal: the surface colour alone separates a card from the page.
            background = rounded(color, dp(24).toFloat())
        }

    /** A frosted card for floating over the map: translucent, with a hairline edge. */
    fun glassCard(padding: Int = 12, spacing: Int = 6, radius: Int = 26, block: LinearLayout.() -> Unit = {}): LinearLayout =
        column(padding, spacing, block).apply {
            background = rounded(p.glass, dp(radius).toFloat(), p.glassStroke, dp(1))
            elevation = dp(6).toFloat()
        }

    enum class B { FILLED, TONAL, OUTLINED, TEXT, DANGER }

    fun button(label: String, icon: Int? = null, style: B = B.FILLED, onClick: () -> Unit): TextView = TextView(ctx).apply {
        text = label
        textSize = 15f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        minHeight = dp(48)
        setPadding(dp(20), dp(10), dp(20), dp(10))
        val (bg, fg) = when (style) {
            B.FILLED -> p.primary to p.onPrimary
            B.TONAL -> p.primaryContainer to p.onPrimaryContainer
            B.OUTLINED -> Color.TRANSPARENT to p.primary
            B.TEXT -> Color.TRANSPARENT to p.primary
            B.DANGER -> p.danger to Color.WHITE
        }
        setTextColor(fg)
        val shape = rounded(bg, dp(28).toFloat(), if (style == B.OUTLINED) p.outline else null, dp(1))
        background = ripple(shape, (fg and 0x00FFFFFF) or 0x33000000, rounded(Color.WHITE, dp(28).toFloat()))
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

    /**
     * Round icon button. Floating on its own it casts a shadow; with [flat] it sits inside a capsule of controls and
     * is only an icon, so six of them read as one tool instead of six circles over the map.
     */
    fun fab(icon: Int, description: String, sizeDp: Int = 48, bg: Int = p.surface, fg: Int = p.onSurface, flat: Boolean = false, onClick: () -> Unit): ImageButton =
        ImageButton(ctx).apply {
            setImageDrawable(ctx.getDrawable(icon)?.mutate()?.apply { setTint(fg) })
            contentDescription = description
            scaleType = ImageView.ScaleType.CENTER
            val mask = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) }
            if (flat) {
                background = ripple(null, 0x33000000, mask)
            } else {
                val circle = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(bg) }
                background = ripple(circle, 0x33000000, mask)
                elevation = dp(4).toFloat()
            }
            layoutParams = LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp))
            setOnClickListener { onClick() }
        }

    /** A pill label. With [glass] it is the compact, frosted kind for floating over the map. */
    fun chip(label: String, selected: Boolean = false, glass: Boolean = false, wrap: Boolean = false, onClick: (() -> Unit)? = null): TextView = TextView(ctx).apply {
        text = label
        textSize = if (glass) 12.5f else 13f
        maxLines = if (wrap) 3 else 1
        ellipsize = TextUtils.TruncateAt.END
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(if (selected) p.onPrimaryContainer else p.onSurface)
        if (glass) {
            setPadding(dp(11), dp(6), dp(11), dp(6))
            background = rounded(if (selected) p.primaryContainer else p.glass, dp(18).toFloat(), p.glassStroke, dp(1))
            elevation = dp(3).toFloat()
        } else {
            setPadding(dp(13), dp(8), dp(13), dp(8))
            background = rounded(if (selected) p.primaryContainer else p.surfaceVariant, dp(18).toFloat())
        }
        if (onClick != null) { isClickable = true; setOnClickListener { onClick() } }
    }

    /**
     * Label over a value, shrunk to fit a weighted column. A value that is a number and a unit ("360 m", "14.8 km/h")
     * is set with a big number and a small unit, so the figure is what the eye lands on.
     */
    fun stat(label: String, value: String, big: Boolean = false): LinearLayout = column {
        addView(text(label, T.LABEL).apply {
            maxLines = 1
            setAutoSizeTextTypeUniformWithConfiguration(8, 12, 1, TypedValue.COMPLEX_UNIT_SP)
        }, lp())
        addView(text(numberAndUnit(value), if (big) T.HEADLINE else T.TITLE).apply {
            maxLines = 1
            setAutoSizeTextTypeUniformWithConfiguration(10, if (big) 28 else 22, 1, TypedValue.COMPLEX_UNIT_SP)
        }, lp())
    }

    private fun numberAndUnit(value: String): CharSequence {
        val m = NUMBER_UNIT.matchEntire(value) ?: return value
        val unitStart = m.groups[2]?.range?.first ?: return value
        return SpannableString(value).apply {
            setSpan(RelativeSizeSpan(0.62f), unitStart, value.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(ForegroundColorSpan(p.muted), unitStart, value.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
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
        setPadding(dp(16), dp(13), dp(16), dp(13))
        background = rounded(p.surfaceVariant, dp(16).toFloat())
    }

    fun switch(label: String, checked: Boolean, onChange: (Boolean) -> Unit): Switch = Switch(ctx).apply {
        text = label
        textSize = 15f
        setTextColor(p.onSurface)
        isChecked = checked
        minHeight = dp(48)
        val on = intArrayOf(android.R.attr.state_checked)
        val off = intArrayOf()
        thumbTintList = ColorStateList(arrayOf(on, off), intArrayOf(p.onPrimary, p.muted))
        trackTintList = ColorStateList(arrayOf(on, off), intArrayOf(p.primary, p.surfaceVariant))
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

    fun help(summary: String, detail: String): View = row(spacing = 4) {
        addView(text(summary, T.CAPTION), lp(0, weight = 1f))
        addView(fab(com.trailmind.app.R.drawable.ic_info, "More information: $summary", flat = true) {
            dialog().setTitle(summary).setMessage(detail).setPositiveButton("OK", null).show()
        })
    }

    /** Keep status below the text so it cannot squeeze names into a narrow column. */
    fun listItem(title: String, subtitle: String?, icon: Int? = null, badge: String? = null, info: String? = null, onClick: () -> Unit): LinearLayout =
        row(spacing = 10) {
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = ripple(rounded(p.surface, dp(24).toFloat()), 0x22000000, rounded(Color.WHITE, dp(24).toFloat()))
            isClickable = true
            setOnClickListener { onClick() }
            if (icon != null) {
                // A rounded square rather than a circle: the tile shape the new look uses throughout.
                addView(ImageView(ctx).apply {
                    setImageDrawable(ctx.getDrawable(icon)?.mutate()?.apply { setTint(p.primary) })
                    background = rounded(p.primaryContainer, dp(13).toFloat())
                    setPadding(dp(10), dp(10), dp(10), dp(10))
                }, LinearLayout.LayoutParams(dp(40), dp(40)))
            }
            addView(column(spacing = 4) {
                addView(text(title, T.TITLE).apply { textSize = 16f; maxLines = 3; ellipsize = TextUtils.TruncateAt.END })
                if (!subtitle.isNullOrBlank()) addView(text(subtitle, T.CAPTION))
                if (badge != null) addView(chip(badge, selected = true), lp(ViewGroup.LayoutParams.WRAP_CONTENT))
            }, lp(0, weight = 1f))
            if (info != null) addView(fab(com.trailmind.app.R.drawable.ic_info, "About $title", flat = true) {
                dialog().setTitle(title).setMessage(info).setPositiveButton("OK", null).show()
            })
        }

    fun banner(message: String, danger: Boolean = false, icon: Int = com.trailmind.app.R.drawable.ic_warning): LinearLayout = row(spacing = 12) {
        setPadding(dp(16), dp(13), dp(16), dp(13))
        background = rounded(if (danger) p.dangerContainer else p.warnContainer, dp(20).toFloat())
        addView(ImageView(ctx).apply {
            setImageDrawable(ctx.getDrawable(icon)?.mutate()?.apply { setTint(if (danger) p.danger else p.accent) })
        }, LinearLayout.LayoutParams(dp(22), dp(22)))
        addView(text(message, T.CAPTION, p.onSurface), lp(0, weight = 1f))
    }

    /** A short title set light then bold ("Trip *group*"); anything with numbers, names or punctuation is left plain. */
    private fun twoTone(title: String): CharSequence {
        val words = title.split(' ')
        if (words.size !in 2..3 || title.any { it.isDigit() || it in "·:,–—&/()" }) return title
        return SpannableString(title).apply {
            setSpan(TypefaceSpan("sans-serif-light"), 0, words[0].length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    /** Header used by every page: back arrow (optional) and title, with any actions on a wrapping row below it. */
    fun header(title: String, onBack: (() -> Unit)?, vararg actions: View): LinearLayout {
        val top = row(spacing = 4) {
            setPadding(dp(4), dp(10), dp(8), dp(6))
            if (onBack != null) {
                addView(ImageButton(ctx).apply {
                    setImageDrawable(ctx.getDrawable(com.trailmind.app.R.drawable.ic_arrow_back)?.mutate()?.apply { setTint(p.onSurface) })
                    contentDescription = "Back"
                    background = ripple(null, 0x22000000, GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) })
                    setOnClickListener { onBack() }
                }, LinearLayout.LayoutParams(dp(48), dp(48)))
            } else addView(View(ctx), LinearLayout.LayoutParams(dp(12), 1))
            // Short titles get the large size; a long one (a hike's name and date) steps down so it stays on one line.
            addView(text(twoTone(title), T.HEADLINE).apply { textSize = if (title.length <= 22) 28f else 22f; maxLines = 2; ellipsize = TextUtils.TruncateAt.END }, lp(0, weight = 1f))
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
