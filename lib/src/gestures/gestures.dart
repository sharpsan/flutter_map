import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map/src/gestures/interactive_flag.dart';
import 'package:flutter_map/src/gestures/latlng_tween.dart';
import 'package:flutter_map/src/map/map.dart';
import 'package:latlong/latlong.dart';
import 'package:positioned_tap_detector/positioned_tap_detector.dart';
import 'package:vector_math/vector_math_64.dart';

abstract class MapGestureMixin extends State<FlutterMap>
    with TickerProviderStateMixin {
  static const double _kMinFlingVelocity = 800.0;

  var _dragMode = false;
  var _gestureWinner = MultiFingerGesture.none;

  var _pointerCounter = 0;
  void savePointer(PointerEvent event) => ++_pointerCounter;
  void removePointer(PointerEvent event) => --_pointerCounter;

  var _rotationStarted = false;
  var _pinchZoomStarted = false;
  var _pinchMoveStarted = false;
  var _dragStarted = false;

  // Helps to reset ScaleUpdateDetails.scale back to 1.0 when a multi finger gesture wins
  double _scaleCorrector;

  /// When a multi finger gesture wins this replaces [_focalStartGlobal]
  LatLng _focalStartGlobalCorrector;

  /// When a multi finger gesture wins this replaces [_focalStartLocal]
  Offset _focalStartLocalCorrector;
  double _lastRotation;
  double _lastScale;
  Offset _lastFocalLocal;

  LatLng _mapCenterStart;
  double _mapZoomStart;
  LatLng _focalStartGlobal;
  Offset _focalStartLocal;

  AnimationController _flingController;
  Animation<Offset> _flingAnimation;
  Offset _flingOffset = Offset.zero;

  AnimationController _doubleTapController;
  Animation _doubleTapZoomAnimation;
  Animation _doubleTapCenterAnimation;

  int _tapUpCounter = 0;
  Timer _doubleTapHoldMaxDelay;

  @override
  FlutterMap get widget;
  MapState get mapState;
  MapOptions get options;

  @override
  void initState() {
    super.initState();
    _flingController = AnimationController(vsync: this)
      ..addListener(_handleFlingAnimation)
      ..addStatusListener(_flingAnimationStatusListener);
    _doubleTapController =
        AnimationController(vsync: this, duration: Duration(milliseconds: 200))
          ..addListener(_handleDoubleTapZoomAnimation)
          ..addStatusListener(_doubleTapZoomStatusListener);
  }

  @override
  void didUpdateWidget(FlutterMap oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldFlags = oldWidget.options.interactiveFlags;
    final flags = options.interactiveFlags;

    final oldGestures =
        _getMultiFingerGestureFlags(mapOptions: oldWidget.options);
    final gestures = _getMultiFingerGestureFlags();

    if (flags != oldFlags || gestures != oldGestures) {
      var emitMapEventMoveEnd = false;

      if (!InteractiveFlag.hasFlag(flags, InteractiveFlag.flingAnimation)) {
        closeFlingController(MapEventSource.interactiveFlagsChanged);
      }
      if (!InteractiveFlag.hasFlag(flags, InteractiveFlag.doubleTapZoom)) {
        closeDoubleTapController(MapEventSource.interactiveFlagsChanged);
      }

      if (_rotationStarted &&
          !(InteractiveFlag.hasFlag(flags, InteractiveFlag.rotate) &&
              MultiFingerGesture.hasFlag(
                  gestures, MultiFingerGesture.rotate))) {
        _rotationStarted = false;

        if (_gestureWinner == MultiFingerGesture.rotate) {
          _gestureWinner = MultiFingerGesture.none;
        }

        mapState.emitMapEvent(
          MapEventRotateEnd(
            center: mapState.center,
            zoom: mapState.zoom,
            source: MapEventSource.interactiveFlagsChanged,
          ),
        );
      }

      if (_pinchZoomStarted &&
          !(InteractiveFlag.hasFlag(flags, InteractiveFlag.pinchZoom) &&
              MultiFingerGesture.hasFlag(
                  gestures, MultiFingerGesture.pinchZoom))) {
        _pinchZoomStarted = false;
        emitMapEventMoveEnd = true;

        if (_gestureWinner == MultiFingerGesture.pinchZoom) {
          _gestureWinner = MultiFingerGesture.none;
        }
      }

      if (_pinchMoveStarted &&
          !(InteractiveFlag.hasFlag(flags, InteractiveFlag.pinchMove) &&
              MultiFingerGesture.hasFlag(
                  gestures, MultiFingerGesture.pinchMove))) {
        _pinchMoveStarted = false;
        emitMapEventMoveEnd = true;

        if (_gestureWinner == MultiFingerGesture.pinchMove) {
          _gestureWinner = MultiFingerGesture.none;
        }
      }

      if (_dragStarted &&
          !InteractiveFlag.hasFlag(flags, InteractiveFlag.drag)) {
        _dragStarted = false;
        emitMapEventMoveEnd = true;
      }

      if (emitMapEventMoveEnd) {
        mapState.emitMapEvent(
          MapEventRotateEnd(
            center: mapState.center,
            zoom: mapState.zoom,
            source: MapEventSource.interactiveFlagsChanged,
          ),
        );
      }
    }
  }

  void _yieldMultiFingerGestureWinner(
      int gestureWinner, bool resetStartVariables) {
    _gestureWinner = gestureWinner;

    if (resetStartVariables) {
      // note: here we could reset to current values instead of last values
      _scaleCorrector = 1.0 - _lastScale;
      _focalStartLocalCorrector = _lastFocalLocal;
      _focalStartGlobalCorrector = _offsetToCrs(_lastFocalLocal, false);
    }
  }

  int _getMultiFingerGestureFlags({int gestureWinner, MapOptions mapOptions}) {
    gestureWinner ??= _gestureWinner;
    mapOptions ??= options;

    if (mapOptions.enableMultiFingerGestureRace) {
      if (gestureWinner == MultiFingerGesture.pinchZoom) {
        return mapOptions.pinchZoomWinGestures;
      } else if (gestureWinner == MultiFingerGesture.rotate) {
        return mapOptions.rotationWinGestures;
      } else if (gestureWinner == MultiFingerGesture.pinchMove) {
        return mapOptions.pinchMoveWinGestures;
      }

      return MultiFingerGesture.none;
    } else {
      return MultiFingerGesture.all;
    }
  }

  void closeFlingController(MapEventSource source) {
    if (_flingController.isAnimating) {
      _flingController.stop();

      mapState.emitMapEvent(
        MapEventFlingAnimationEnd(
            center: mapState.center, zoom: mapState.zoom, source: source),
      );
    }
  }

  void closeDoubleTapController(MapEventSource source) {
    if (_doubleTapController.isAnimating) {
      _doubleTapController.stop();

      mapState.emitMapEvent(
        MapEventDoubleTapZoomEnd(
            center: mapState.center, zoom: mapState.zoom, source: source),
      );
    }
  }

  void handleScaleStart(ScaleStartDetails details) {
    _dragMode = _pointerCounter == 1;

    final eventSource = _dragMode
        ? MapEventSource.dragStart
        : MapEventSource.multiFingerGestureStart;
    closeFlingController(eventSource);
    closeDoubleTapController(eventSource);

    _gestureWinner = MultiFingerGesture.none;

    _mapZoomStart = mapState.zoom;
    _mapCenterStart = mapState.center;

    _dragStarted = false;
    _pinchZoomStarted = false;
    _pinchMoveStarted = false;
    _rotationStarted = false;

    _lastRotation = 0.0;
    _scaleCorrector = 0.0;
    _lastScale = 1.0;

    // determine the focal point within the widget
    final focalOffset = details.localFocalPoint;
    _focalStartLocalCorrector =
        _focalStartLocal = _lastFocalLocal = focalOffset;
    _focalStartGlobalCorrector =
        _focalStartGlobal = _offsetToCrs(focalOffset, false);
  }

  void handleScaleUpdate(ScaleUpdateDetails details) {
    if (_tapUpCounter == 1) {
      _handleDoubleTapHold(details);
      return;
    }

    final eventSource =
        _dragMode ? MapEventSource.onDrag : MapEventSource.onMultiFinger;

    final flags = options.interactiveFlags;
    final focalOffset = details.localFocalPoint;

    final currentRotation = radianToDeg(details.rotation);
    _flingOffset = _focalStartLocal - focalOffset;

    if (_dragMode) {
      if (InteractiveFlag.hasFlag(flags, InteractiveFlag.drag)) {
        if (!_dragStarted) {
          // we could emit start event at [handleScaleStart], however it is
          // possible drag will be disabled during ongoing drag then [didUpdateWidget]
          // will emit MapEventMoveEnd and if drag is enabled again then this will emit the start event again
          _dragStarted = true;
          mapState.emitMapEvent(
            MapEventMoveStart(
              center: mapState.center,
              zoom: mapState.zoom,
              source: eventSource,
            ),
          );
        }

        final focalStartPt = mapState.project(_focalStartGlobal, mapState.zoom);
        final newCenterPt =
            focalStartPt - _offsetToPoint(focalOffset) + (mapState.size / 2.0);
        var newCenter = mapState.unproject(newCenterPt, mapState.zoom);

        mapState.move(
          newCenter,
          mapState.zoom,
          hasGesture: true,
          source: eventSource,
        );
      }
    } else {
      final hasIntPinchMove =
          InteractiveFlag.hasFlag(flags, InteractiveFlag.pinchMove);
      final hasIntPinchZoom =
          InteractiveFlag.hasFlag(flags, InteractiveFlag.pinchZoom);
      final hasIntRotate =
          InteractiveFlag.hasFlag(flags, InteractiveFlag.rotate);

      if (hasIntPinchMove || hasIntPinchZoom || hasIntRotate) {
        final hasGestureRace = options.enableMultiFingerGestureRace;

        if (hasGestureRace && _gestureWinner == MultiFingerGesture.none) {
          if (hasIntPinchZoom &&
              (_getZoomForScale(_mapZoomStart, details.scale) - _mapZoomStart)
                      .abs() >=
                  options.pinchZoomThreshold) {
            if (options.debugMultiFingerGestureWinner) {
              print('Multi Finger Gesture winner: Pinch Zoom');
            }
            _yieldMultiFingerGestureWinner(MultiFingerGesture.pinchZoom, true);
          } else if (hasIntRotate &&
              currentRotation.abs() >= options.rotationThreshold) {
            if (options.debugMultiFingerGestureWinner) {
              print('Multi Finger Gesture winner: Rotate');
            }
            _yieldMultiFingerGestureWinner(MultiFingerGesture.rotate, true);
          } else if (hasIntPinchMove &&
              _flingOffset.distance >= options.pinchMoveThreshold) {
            if (options.debugMultiFingerGestureWinner) {
              print('Multi Finger Gesture winner: Pinch Move');
            }
            _yieldMultiFingerGestureWinner(MultiFingerGesture.pinchMove, true);
          }
        }

        if (!hasGestureRace || _gestureWinner != MultiFingerGesture.none) {
          final gestures = _getMultiFingerGestureFlags();

          final hasGesturePinchMove = MultiFingerGesture.hasFlag(
              gestures, MultiFingerGesture.pinchMove);
          final hasGesturePinchZoom = MultiFingerGesture.hasFlag(
              gestures, MultiFingerGesture.pinchZoom);
          final hasGestureRotate =
              MultiFingerGesture.hasFlag(gestures, MultiFingerGesture.rotate);

          final hasMove = hasIntPinchMove && hasGesturePinchMove;
          final hasZoom = hasIntPinchZoom && hasGesturePinchZoom;
          final hasRotate = hasIntRotate && hasGestureRotate;

          var mapMoved = false;
          if (hasMove || hasZoom) {
            double newZoom;
            if (hasZoom) {
              newZoom = _getZoomForScale(
                  _mapZoomStart, details.scale + _scaleCorrector);

              if (!_pinchZoomStarted) {
                if (newZoom != _mapZoomStart) {
                  _pinchZoomStarted = true;

                  if (!_pinchMoveStarted) {
                    // emit MoveStart event only if pinchMove hasn't started
                    mapState.emitMapEvent(
                      MapEventMoveStart(
                        center: mapState.center,
                        zoom: mapState.zoom,
                        source: eventSource,
                      ),
                    );
                  }
                }
              }
            } else {
              newZoom = mapState.zoom;
            }

            LatLng newCenter;
            if (hasMove) {
              if (!_pinchMoveStarted &&
                  _focalStartLocalCorrector != focalOffset) {
                _pinchMoveStarted = true;

                if (!_pinchZoomStarted) {
                  // emit MoveStart event only if pinchZoom hasn't started
                  mapState.emitMapEvent(
                    MapEventMoveStart(
                      center: mapState.center,
                      zoom: mapState.zoom,
                      source: eventSource,
                    ),
                  );
                }
              }

              if (_pinchMoveStarted) {
                final focalStartPt =
                    mapState.project(_focalStartGlobalCorrector, newZoom);
                final newCenterPt = focalStartPt -
                    _offsetToPoint(focalOffset) +
                    (mapState.size / 2.0);

                newCenter = mapState.unproject(newCenterPt, newZoom);
              } else {
                newCenter = mapState.center;
              }
            } else {
              newCenter = mapState.center;
            }

            mapMoved = mapState.move(
              newCenter,
              newZoom,
              hasGesture: true,
              source: eventSource,
            );
          }

          var rotationDiff = currentRotation - _lastRotation;

          if (hasRotate) {
            if (!_rotationStarted && currentRotation != 0.0) {
              _rotationStarted = true;
              mapState.emitMapEvent(
                MapEventRotateStart(
                  center: mapState.center,
                  zoom: mapState.zoom,
                  source: eventSource,
                ),
              );
            }

            if (_rotationStarted) {
              mapState.rotate(
                mapState.rotation + rotationDiff,
                hasGesture: true,
                simulateMove: !mapMoved,
                source: eventSource,
              );
            }
          }
        }
      }
    }

    _lastRotation = currentRotation;
    _lastScale = details.scale;
    _lastFocalLocal = focalOffset;
  }

  void handleScaleEnd(ScaleEndDetails details) {
    _resetDoubleTapHold();

    final eventSource =
        _dragMode ? MapEventSource.dragEnd : MapEventSource.multiFingerEnd;

    if (_rotationStarted) {
      _rotationStarted = false;
      mapState.emitMapEvent(
        MapEventRotateEnd(
          center: mapState.center,
          zoom: mapState.zoom,
          source: eventSource,
        ),
      );
    }

    if (_dragStarted || _pinchZoomStarted || _pinchMoveStarted) {
      _dragStarted = _pinchZoomStarted = _pinchMoveStarted = false;
      mapState.emitMapEvent(
        MapEventMoveEnd(
          center: mapState.center,
          zoom: mapState.zoom,
          source: eventSource,
        ),
      );
    }

    var hasFling = InteractiveFlag.hasFlag(
        options.interactiveFlags, InteractiveFlag.flingAnimation);
    var magnitude = details.velocity.pixelsPerSecond.distance;
    if (magnitude < _kMinFlingVelocity || !hasFling) {
      if (hasFling) {
        mapState.emitMapEvent(
          MapEventFlingAnimationNotStarted(
            center: mapState.center,
            zoom: mapState.zoom,
            source: eventSource,
          ),
        );
      }

      return;
    }

    var direction = details.velocity.pixelsPerSecond / magnitude;
    var distance =
        (Offset.zero & Size(mapState.size.x, mapState.size.y)).shortestSide;

    if (mapState.rotation != 0.0) {
      // correct fling direction with rotation
      var v = Matrix4.rotationZ(-mapState.rotationRad) *
          Vector4(direction.dx, direction.dy, 0, 0);
      direction = Offset(v.x, v.y);
    }

    _flingAnimation = Tween<Offset>(
      begin: _flingOffset,
      end: _flingOffset - direction * distance,
    ).animate(_flingController);

    _flingController
      ..value = 0.0
      ..fling(velocity: magnitude / 1000.0);
  }

  void handleTap(TapPosition position) {
    closeFlingController(MapEventSource.tap);
    closeDoubleTapController(MapEventSource.tap);

    final latlng = _offsetToCrs(position.relative, true);
    if (options.onTap != null) {
      // emit the event
      options.onTap(latlng);
    }

    mapState.emitMapEvent(
      MapEventTap(
        tapPosition: latlng,
        center: mapState.center,
        zoom: mapState.zoom,
        source: MapEventSource.tap,
      ),
    );
  }

  void handleLongPress(TapPosition position) {
    _resetDoubleTapHold();

    closeFlingController(MapEventSource.longPress);
    closeDoubleTapController(MapEventSource.longPress);

    final latlng = _offsetToCrs(position.relative, true);
    if (options.onLongPress != null) {
      // emit the event
      options.onLongPress(latlng);
    }

    mapState.emitMapEvent(
      MapEventLongPress(
        tapPosition: latlng,
        center: mapState.center,
        zoom: mapState.zoom,
        source: MapEventSource.longPress,
      ),
    );
  }

  LatLng _offsetToCrs(Offset offset, bool correctOffsetWithRotation) {
    var width = mapState.size.x;
    var height = mapState.size.y;

    if (correctOffsetWithRotation && mapState.rotation != 0.0) {
      // correct offset with rotation
      var v = Matrix4.rotationZ(-mapState.rotationRad) *
          Vector4(offset.dx, offset.dy, 0, 0);
      offset = Offset(v.x, v.y);
    }

    // convert the point to global coordinates
    var localPoint = _offsetToPoint(offset);
    var localPointCenterDistance =
        CustomPoint((width / 2) - localPoint.x, (height / 2) - localPoint.y);
    var mapCenter = mapState.project(mapState.center);
    var point = mapCenter - localPointCenterDistance;
    return mapState.unproject(point);
  }

  void handleDoubleTap(TapPosition tapPosition) {
    _resetDoubleTapHold();

    closeFlingController(MapEventSource.doubleTap);
    closeDoubleTapController(MapEventSource.doubleTap);

    if (InteractiveFlag.hasFlag(
        options.interactiveFlags, InteractiveFlag.doubleTapZoom)) {
      final centerPos = _pointToOffset(mapState.size) / 2.0;
      final newZoom = _getZoomForScale(mapState.zoom, 2.0);
      final focalDelta = _getDoubleTapFocalDelta(
          centerPos, tapPosition.relative, newZoom - mapState.zoom);
      final newCenter = _offsetToCrs(centerPos + focalDelta, true);
      _startDoubleTapAnimation(newZoom, newCenter);
    }
  }

  Offset _getDoubleTapFocalDelta(
      Offset centerPos, Offset tapPos, double zoomDiff) {
    final tapDelta = tapPos - centerPos;
    final zoomScale = 1 / math.pow(2, zoomDiff);
    // map center offset within which double-tap won't
    // cause zooming to previously invisible area
    final maxDelta = centerPos * (1 - zoomScale);
    final tappedOutExtent =
        tapDelta.dx.abs() > maxDelta.dx || tapDelta.dy.abs() > maxDelta.dy;
    return tappedOutExtent
        ? _projectDeltaOnBounds(tapDelta, maxDelta)
        : tapDelta;
  }

  Offset _projectDeltaOnBounds(Offset delta, Offset maxDelta) {
    final weightX = delta.dx.abs() / maxDelta.dx;
    final weightY = delta.dy.abs() / maxDelta.dy;
    return delta / math.max(weightX, weightY);
  }

  void _startDoubleTapAnimation(double newZoom, LatLng newCenter) {
    _doubleTapZoomAnimation = Tween<double>(begin: mapState.zoom, end: newZoom)
        .chain(CurveTween(curve: Curves.fastOutSlowIn))
        .animate(_doubleTapController);
    _doubleTapCenterAnimation =
        LatLngTween(begin: mapState.center, end: newCenter)
            .chain(CurveTween(curve: Curves.fastOutSlowIn))
            .animate(_doubleTapController);
    _doubleTapController.forward(from: 0.0);
  }

  void _doubleTapZoomStatusListener(AnimationStatus status) {
    if (status == AnimationStatus.forward) {
      mapState.emitMapEvent(
        MapEventDoubleTapZoomStart(
            center: mapState.center,
            zoom: mapState.zoom,
            source: MapEventSource.doubleTapZoomAnimationController),
      );
    } else if (status == AnimationStatus.completed) {
      mapState.emitMapEvent(
        MapEventDoubleTapZoomEnd(
            center: mapState.center,
            zoom: mapState.zoom,
            source: MapEventSource.doubleTapZoomAnimationController),
      );
    }
  }

  void _handleDoubleTapZoomAnimation() {
    mapState.move(
      _doubleTapCenterAnimation.value,
      _doubleTapZoomAnimation.value,
      hasGesture: true,
      source: MapEventSource.doubleTapZoomAnimationController,
    );
  }

  void handleOnTapUp(TapUpDetails details) {
    _doubleTapHoldMaxDelay?.cancel();

    if (++_tapUpCounter == 1) {
      _doubleTapHoldMaxDelay =
          Timer(const Duration(milliseconds: 350), _resetDoubleTapHold);
    }
  }

  void _handleDoubleTapHold(ScaleUpdateDetails details) {
    _doubleTapHoldMaxDelay?.cancel();

    var flags = options.interactiveFlags;
    // TODO: is this pinchZoom? never seen this fired
    if (InteractiveFlag.hasFlag(flags, InteractiveFlag.pinchZoom)) {
      final zoom = mapState.zoom;
      final focalOffset = details.localFocalPoint;
      final verticalOffset = (_focalStartLocal - focalOffset).dy;
      final newZoom = _mapZoomStart - verticalOffset / 360 * zoom;
      final min = options.minZoom ?? 0.0;
      final max = options.maxZoom ?? double.infinity;
      final actualZoom = math.max(min, math.min(max, newZoom));

      mapState.move(
        mapState.center,
        actualZoom,
        hasGesture: true,
        source: MapEventSource.doubleTapHold,
      );
    }
  }

  void _resetDoubleTapHold() {
    _doubleTapHoldMaxDelay?.cancel();
    _tapUpCounter = 0;
  }

  void _flingAnimationStatusListener(AnimationStatus status) {
    if (status == AnimationStatus.forward) {
      mapState.emitMapEvent(
        MapEventFlingAnimationStart(
            center: mapState.center,
            zoom: mapState.zoom,
            source: MapEventSource.flingAnimationController),
      );
    } else if (status == AnimationStatus.completed) {
      mapState.emitMapEvent(
        MapEventFlingAnimationEnd(
            center: mapState.center,
            zoom: mapState.zoom,
            source: MapEventSource.flingAnimationController),
      );
    }
  }

  void _handleFlingAnimation() {
    _flingOffset = _flingAnimation.value;
    var newCenterPoint = mapState.project(_mapCenterStart) +
        CustomPoint(_flingOffset.dx, _flingOffset.dy);
    var newCenter = mapState.unproject(newCenterPoint);
    mapState.move(
      newCenter,
      mapState.zoom,
      hasGesture: true,
      source: MapEventSource.flingAnimationController,
    );
  }

  CustomPoint _offsetToPoint(Offset offset) {
    return CustomPoint(offset.dx, offset.dy);
  }

  Offset _pointToOffset(CustomPoint point) {
    return Offset(point.x.toDouble(), point.y.toDouble());
  }

  double _getZoomForScale(double startZoom, double scale) {
    var resultZoom =
        scale == 1.0 ? startZoom : startZoom + math.log(scale) / math.ln2;
    return mapState.fitZoomToBounds(resultZoom);
  }

  @override
  void dispose() {
    _flingController.dispose();
    _doubleTapController.dispose();
    super.dispose();
  }
}
