import 'package:flutter/material.dart';

/// One line of text that, when it is too long for its width, scrolls slowly
/// to its end and back, pausing at each end, so all of it can be read. It
/// sits still when it fits, and shows an ellipsis instead of moving when
/// the platform asks for animations off. The Chat pane's conversation name.
class MarqueeText extends StatelessWidget {
  const MarqueeText(
    this.text, {
    super.key,
    required this.style,
    this.speed = 25,
    this.pause = const Duration(milliseconds: 1500),
  });

  final String text;
  final TextStyle style;

  /// Logical pixels a second.
  final double speed;

  /// How long it rests at each end.
  final Duration pause;

  @override
  Widget build(BuildContext context) {
    final still = Text(text,
        maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
        style: style);
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return still;
    return LayoutBuilder(builder: (context, box) {
      if (!box.hasBoundedWidth) return still;
      final painter = TextPainter(
        text: TextSpan(text: text, style: DefaultTextStyle.of(context).style
            .merge(style)),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final overflow = painter.width - box.maxWidth;
      final height = painter.height;
      painter.dispose();
      if (overflow <= 0.5) return still;
      return Tooltip(
        message: text,
        waitDuration: const Duration(milliseconds: 600),
        child: SizedBox(
          width: box.maxWidth,
          height: height,
          child: _Scroller(
            // A different text starts again from its beginning.
            key: ValueKey(text),
            overflow: overflow,
            speed: speed,
            pause: pause,
            child: Text(text,
                maxLines: 1, softWrap: false, style: style),
          ),
        ),
      );
    });
  }
}

class _Scroller extends StatefulWidget {
  const _Scroller({
    super.key,
    required this.overflow,
    required this.speed,
    required this.pause,
    required this.child,
  });

  final double overflow;
  final double speed;
  final Duration pause;
  final Widget child;

  @override
  State<_Scroller> createState() => _ScrollerState();
}

class _ScrollerState extends State<_Scroller>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this);
  late Animation<double> _offset;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_Scroller old) {
    super.didUpdateWidget(old);
    // The width changed (the pane resized, Rename came or went): the same
    // pace over the new distance.
    if (old.overflow != widget.overflow ||
        old.speed != widget.speed ||
        old.pause != widget.pause) {
      _start();
    }
  }

  /// One leg is half the pause, the travel, and half the pause, run there
  /// and back by `repeat(reverse: true)`: each turn rests the arriving
  /// half and the leaving one — the whole pause.
  void _start() {
    final travel = Duration(
        milliseconds: (widget.overflow / widget.speed * 1000).round());
    final leg = travel + widget.pause;
    final hold = widget.pause.inMilliseconds / 2 / leg.inMilliseconds;
    _offset = CurvedAnimation(
      parent: _controller,
      curve: Interval(hold, 1 - hold, curve: Curves.easeInOut),
    );
    _controller
      ..duration = leg
      ..value = 0
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // It moves for as long as a long name is open: its own layer, so the
    // pane around it is not repainted every frame.
    return RepaintBoundary(
      child: ClipRect(
        child: OverflowBox(
          alignment: AlignmentDirectional.centerStart,
          minWidth: 0,
          maxWidth: double.infinity,
          child: AnimatedBuilder(
            animation: _offset,
            builder: (context, child) => Transform.translate(
              offset: Offset(
                  -widget.overflow *
                      _offset.value *
                      (Directionality.of(context) == TextDirection.rtl ? -1 : 1),
                  0),
              child: child,
            ),
            child: widget.child,
          ),
        ),
        ),
    );
  }
}
