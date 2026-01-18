import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'package:image/image.dart' as img;
import 'dart:math' as math;

class PointCloudViewerScreen extends StatefulWidget {
  const PointCloudViewerScreen({super.key});

  @override
  State<PointCloudViewerScreen> createState() => _PointCloudViewerScreenState();
}

class _PointCloudViewerScreenState extends State<PointCloudViewerScreen> {
  List<Directory> _sessions = [];
  bool _loading = true;
  Directory? _selectedSession;
  List<Map<String, dynamic>> _captures = [];
  int _currentIndex = 0;
  List<Point3D>? _pointCloud;
  double _rotationX = -0.5;
  double _rotationY = 0.0;
  double _zoom = 1.0;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final appDir = await getApplicationDocumentsDirectory();
    final capturesDir = Directory('${appDir.path}/captures');
    if (await capturesDir.exists()) {
      final entities = capturesDir.listSync();
      _sessions = entities.whereType<Directory>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
    }
    setState(() {
      _loading = false;
    });
  }

  Future<void> _loadCapturesFromSession(Directory session) async {
    setState(() {
      _selectedSession = session;
      _captures = [];
      _currentIndex = 0;
      _pointCloud = null;
    });

    final jsonFile = File('${session.path}/captures.json');
    if (await jsonFile.exists()) {
      final jsonContent = await jsonFile.readAsString();
      final List<dynamic> data = json.decode(jsonContent);
      setState(() {
        _captures = data.cast<Map<String, dynamic>>();
      });
    }
  }

  Future<void> _generatePointCloud() async {
    if (_captures.isEmpty || _currentIndex >= _captures.length) return;

    setState(() {
      _pointCloud = null;
    });

    try {
      final capture = _captures[_currentIndex];
      final imagePath = capture['imagePath'];
      final depthPath = capture['depthPath'];

      // Load RGB image
      final imageBytes = await File(imagePath).readAsBytes();
      final rgbImage = img.decodeImage(imageBytes);
      
      if (rgbImage == null) {
        throw Exception('Failed to decode RGB image');
      }

      // Load depth data (16-bit binary)
      final depthBytes = await File(depthPath).readAsBytes();
      final depthData = depthBytes.buffer.asUint16List();

      // ARCore depth is typically 160x90
      const depthWidth = 160;
      const depthHeight = 90;

      final points = <Point3D>[];
      
      // Camera intrinsics (approximate for visualization)
      final fx = depthWidth / 2.0; // Focal length x
      final fy = depthHeight / 2.0; // Focal length y
      final cx = depthWidth / 2.0; // Principal point x
      final cy = depthHeight / 2.0; // Principal point y

      // Generate point cloud
      for (int y = 0; y < depthHeight; y++) {
        for (int x = 0; x < depthWidth; x++) {
          final depthIndex = y * depthWidth + x;
          if (depthIndex >= depthData.length) continue;

          final depthValue = depthData[depthIndex];
          if (depthValue == 0) continue; // Skip invalid depth

          // Convert depth from millimeters to meters
          final z = depthValue / 1000.0;

          // Back-project to 3D using pinhole camera model
          final xPos = (x - cx) * z / fx;
          final yPos = (y - cy) * z / fy;

          // Get RGB color from image (scaled to depth resolution)
          final imgX = (x * rgbImage.width / depthWidth).floor();
          final imgY = (y * rgbImage.height / depthHeight).floor();
          
          if (imgX >= 0 && imgX < rgbImage.width && imgY >= 0 && imgY < rgbImage.height) {
            final pixel = rgbImage.getPixel(imgX, imgY);
            points.add(Point3D(
              x: xPos,
              y: yPos,
              z: z,
              r: pixel.r.toInt(),
              g: pixel.g.toInt(),
              b: pixel.b.toInt(),
            ));
          }
        }
      }

      setState(() {
        _pointCloud = points;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error generating point cloud: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('3D Viewer')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_selectedSession == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Select Session')),
        body: _sessions.isEmpty
            ? const Center(child: Text('No sessions found'))
            : ListView.builder(
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final session = _sessions[index];
                  final sessionName = session.path.split('/').last;
                  return ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(sessionName),
                    onTap: () => _loadCapturesFromSession(session),
                  );
                },
              ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('3D Viewer (${_currentIndex + 1}/${_captures.length})'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            setState(() {
              _selectedSession = null;
              _captures = [];
              _currentIndex = 0;
              _pointCloud = null;
            });
          },
        ),
      ),
      body: _captures.isEmpty
          ? const Center(child: Text('No captures in this session'))
          : Column(
              children: [
                Expanded(
                  child: _pointCloud == null
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.view_in_ar, size: 64, color: Colors.grey),
                              const SizedBox(height: 16),
                              const Text('No point cloud generated'),
                              const SizedBox(height: 8),
                              ElevatedButton.icon(
                                onPressed: _generatePointCloud,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Generate Point Cloud'),
                              ),
                            ],
                          ),
                        )
                      : GestureDetector(
                          onPanUpdate: (details) {
                            setState(() {
                              _rotationY += details.delta.dx * 0.01;
                              _rotationX += details.delta.dy * 0.01;
                            });
                          },
                          onScaleUpdate: (details) {
                            setState(() {
                              _zoom = (_zoom * details.scale).clamp(0.5, 5.0);
                            });
                          },
                          child: CustomPaint(
                            painter: PointCloudPainter(
                              points: _pointCloud!,
                              rotationX: _rotationX,
                              rotationY: _rotationY,
                              zoom: _zoom,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                ),
                if (_pointCloud != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    color: Colors.black87,
                    child: Text(
                      '${_pointCloud!.length} points | Drag to rotate | Pinch to zoom',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _currentIndex > 0
                            ? () {
                                setState(() {
                                  _currentIndex--;
                                  _pointCloud = null;
                                });
                              }
                            : null,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Previous'),
                      ),
                      ElevatedButton.icon(
                        onPressed: _generatePointCloud,
                        icon: const Icon(Icons.threed_rotation),
                        label: const Text('Generate 3D'),
                      ),
                      ElevatedButton.icon(
                        onPressed: _currentIndex < _captures.length - 1
                            ? () {
                                setState(() {
                                  _currentIndex++;
                                  _pointCloud = null;
                                });
                              }
                            : null,
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Next'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class Point3D {
  final double x, y, z;
  final int r, g, b;

  Point3D({
    required this.x,
    required this.y,
    required this.z,
    required this.r,
    required this.g,
    required this.b,
  });
}

class PointCloudPainter extends CustomPainter {
  final List<Point3D> points;
  final double rotationX;
  final double rotationY;
  final double zoom;

  PointCloudPainter({
    required this.points,
    required this.rotationX,
    required this.rotationY,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final scale = math.min(size.width, size.height) * 0.3 * zoom;

    // Sort points by depth for correct rendering
    final sortedPoints = List<Point3D>.from(points);
    sortedPoints.sort((a, b) {
      final aZ = _rotateZ(a);
      final bZ = _rotateZ(b);
      return aZ.compareTo(bZ);
    });

    for (final point in sortedPoints) {
      // Apply rotation
      final rotated = _rotate3D(point);

      // Project to 2D
      final screenX = centerX + rotated.x * scale;
      final screenY = centerY - rotated.y * scale;

      // Draw point
      final paint = Paint()
        ..color = Color.fromRGBO(point.r, point.g, point.b, 1.0)
        ..strokeWidth = 2;

      canvas.drawCircle(Offset(screenX, screenY), 1, paint);
    }
  }

  Point3D _rotate3D(Point3D point) {
    // Rotate around X axis
    final cosX = math.cos(rotationX);
    final sinX = math.sin(rotationX);
    final y1 = point.y * cosX - point.z * sinX;
    final z1 = point.y * sinX + point.z * cosX;

    // Rotate around Y axis
    final cosY = math.cos(rotationY);
    final sinY = math.sin(rotationY);
    final x2 = point.x * cosY + z1 * sinY;
    final z2 = -point.x * sinY + z1 * cosY;

    return Point3D(x: x2, y: y1, z: z2, r: point.r, g: point.g, b: point.b);
  }

  double _rotateZ(Point3D point) {
    final cosX = math.cos(rotationX);
    final sinX = math.sin(rotationX);
    final z1 = point.y * sinX + point.z * cosX;

    final cosY = math.cos(rotationY);
    final sinY = math.sin(rotationY);
    final z2 = -point.x * sinY + z1 * cosY;

    return z2;
  }

  @override
  bool shouldRepaint(PointCloudPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.rotationX != rotationX ||
        oldDelegate.rotationY != rotationY ||
        oldDelegate.zoom != zoom;
  }
}
