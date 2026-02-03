import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'package:image/image.dart' as img;
import 'dart:math' as math;
import 'utils/session_metadata.dart';
import 'utils/point_cloud_filter.dart';

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
  double _offsetX = 0.0;
  double _offsetY = 0.0;
  bool _useMidasDepth = false;
  FilterMode _filterMode = FilterMode.none;
  String? _statusMessage;

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

  Future<void> _renameSession(Directory sessionDir) async {
    final currentAlias = await SessionMetadata.getSessionAlias(sessionDir);
    final controller = TextEditingController(text: currentAlias);
    
    if (!mounted) return;
    final newAlias = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Session'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Original: ${sessionDir.path.split(Platform.pathSeparator).last}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                hintText: 'Enter custom name',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    
    if (newAlias != null && newAlias.isNotEmpty) {
      try {
        await SessionMetadata.setSessionAlias(sessionDir, newAlias);
        if (!mounted) return;
        setState(() {}); // Refresh the list
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Session name updated successfully')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update name: $e')),
        );
      }
    }
  }

  Future<void> _deleteSession(Directory sessionDir) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Session'),
        content: const Text('Are you sure you want to delete this session? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      try {
        await sessionDir.delete(recursive: true);
        await _loadSessions();
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Session deleted successfully')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e')),
          );
        }
      }
    }
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
      
      // Reconstruct paths based on current session directory
      final fixedCaptures = data.map((capture) {
        final captureMap = Map<String, dynamic>.from(capture);
        
        // Extract just the filename from the stored paths
        final imageFilename = captureMap['imagePath'].toString().split('/').last.split('\\').last;
        final depthFilename = captureMap['depthPath'].toString().split('/').last.split('\\').last;
        
        // Reconstruct full paths based on current session directory
        captureMap['imagePath'] = '${session.path}/$imageFilename';
        captureMap['depthPath'] = '${session.path}/$depthFilename';
        
        return captureMap;
      }).toList();
      
      setState(() {
        _captures = fixedCaptures;
      });
    }
  }

  Future<void> _generatePointCloud() async {
    if (_captures.isEmpty || _currentIndex >= _captures.length) return;

    setState(() {
      _pointCloud = null;
      _statusMessage = 'Generating 3D point cloud...';
    });

    try {
      final capture = _captures[_currentIndex];
      final imagePath = capture['imagePath'];
      final depthPath = capture['depthPath'];
      
      double minDepth = double.infinity;
      double maxDepth = 0.0;

      // Check if MiDaS enhanced depth exists
      final sessionDir = _selectedSession!.path;
      final depthFilename = depthPath.split('/').last;
      final frameNumber = depthFilename.replaceAll(RegExp(r'[^0-9]'), '');
      final midasDepthPath = '$sessionDir/enhanced_depth_$frameNumber.raw';
      
      String actualDepthPath = depthPath;
      bool usingMidas = false;
      
      if (_useMidasDepth && await File(midasDepthPath).exists()) {
        actualDepthPath = midasDepthPath;
        usingMidas = true;
      }

      // Load RGB image
      final imageBytes = await File(imagePath).readAsBytes();
      final rgbImage = img.decodeImage(imageBytes);
      
      if (rgbImage == null) {
        throw Exception('Failed to decode RGB image');
      }

      // Load depth data
      Uint16List depthData;
      int depthWidth, depthHeight;
      
      if (usingMidas) {
        // MiDaS depth (256x256)
        final depthBytes = await File(actualDepthPath).readAsBytes();
        depthData = depthBytes.buffer.asUint16List();
        depthWidth = 256;
        depthHeight = 256;
      } else {
        // ARCore depth (160x90)
        final depthBytes = await File(actualDepthPath).readAsBytes();
        depthData = depthBytes.buffer.asUint16List();
        depthWidth = 160;
        depthHeight = 90;
      }

      final points = <Point3D>[];
      
      // Apply object filtering mask
      Uint8List? filterMask;
      if (_filterMode != FilterMode.none) {
        filterMask = PointCloudFilter.depthBasedMask(
          depthData,
          depthWidth,
          depthHeight,
          mode: _filterMode,
        );
      }
      
      // Normalize MiDaS depth to reasonable metric scale
      if (usingMidas) {
        // Find actual depth range in MiDaS data
        for (int i = 0; i < depthData.length; i++) {
          if (depthData[i] > 0) {
            final d = depthData[i].toDouble();
            if (d < minDepth) minDepth = d;
            if (d > maxDepth) maxDepth = d;
          }
        }
      }
      
      // Camera intrinsics (adjust FOV for more accurate projection)
      // Using ~60 degree horizontal FOV (typical mobile camera)
      final fovH = 60.0 * math.pi / 180.0; // radians
      final fx = depthWidth / (2.0 * math.tan(fovH / 2.0));
      final fy = fx; // Assume square pixels
      final cx = depthWidth / 2.0;
      final cy = depthHeight / 2.0;

      // Downsample for performance (every Nth pixel)
      final step = usingMidas ? 2 : 1;
      
      int filteredCount = 0;
      int totalCount = 0;

      // Generate point cloud
      for (int y = 0; y < depthHeight; y += step) {
        for (int x = 0; x < depthWidth; x += step) {
          final depthIndex = y * depthWidth + x;
          if (depthIndex >= depthData.length) continue;
          
          totalCount++;

          // Check filter mask
          if (filterMask != null && filterMask[depthIndex] == 0) {
            filteredCount++;
            continue;
          }

          final depthValue = depthData[depthIndex];
          if (depthValue == 0) continue;

          double z;
          if (usingMidas) {
            // MiDaS: normalize relative depth to metric scale (0.5m to 3m range)
            // Invert because MiDaS saves closer objects with higher values
            final normalizedDepth = (maxDepth - depthValue.toDouble()) / (maxDepth - minDepth);
            z = 0.5 + normalizedDepth * 2.5; // Map to 0.5m - 3.0m range
          } else {
            // ARCore: already in millimeters
            z = depthValue / 1000.0;
          }
          
          // Skip if depth is too far or too close
          if (z < 0.1 || z > 5.0) continue;

          // Back-project to 3D using proper camera model
          final xPos = (x - cx) * z / fx;
          final yPos = (y - cy) * z / fy;

          // Get RGB color - match depth pixel to RGB pixel
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
        final filterInfo = _filterMode != FilterMode.none 
            ? ' | Filtered: ${filteredCount}/${totalCount} points removed'
            : '';
        final depthInfo = usingMidas && minDepth != double.infinity 
            ? ' | Range: ${(minDepth/1000).toStringAsFixed(2)}-${(maxDepth/1000).toStringAsFixed(2)}m'
            : '';
        _statusMessage = '${points.length} points | ${usingMidas ? "MiDaS" : "ARCore"} depth$depthInfo$filterInfo';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
      });
      if (!mounted) return;
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
                  return FutureBuilder<String>(
                    future: SessionMetadata.getSessionAlias(session),
                    builder: (context, snapshot) {
                      final displayName = snapshot.data ?? sessionName;
                      return ListTile(
                        leading: const Icon(Icons.folder),
                        title: Text(displayName),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: () => _renameSession(session),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _deleteSession(session),
                            ),
                          ],
                        ),
                        onTap: () => _loadCapturesFromSession(session),
                      );
                    },
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
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                onPressed: _generatePointCloud,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Generate Point Cloud'),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Text('Use MiDaS Depth: '),
                                  Switch(
                                    value: _useMidasDepth,
                                    onChanged: (value) {
                                      setState(() {
                                        _useMidasDepth = value;
                                        _pointCloud = null;
                                      });
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Object filtering dropdown
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 32),
                                child: Column(
                                  children: [
                                    const Text('Object Filtering:'),
                                    const SizedBox(height: 8),
                                    DropdownButton<FilterMode>(
                                      value: _filterMode,
                                      isExpanded: true,
                                      items: const [
                                        DropdownMenuItem(
                                          value: FilterMode.none,
                                          child: Text('None (All points)'),
                                        ),
                                        DropdownMenuItem(
                                          value: FilterMode.autoForeground,
                                          child: Text('Auto Foreground'),
                                        ),
                                        DropdownMenuItem(
                                          value: FilterMode.centerObject,
                                          child: Text('Center Object'),
                                        ),
                                        DropdownMenuItem(
                                          value: FilterMode.depthRange,
                                          child: Text('Depth Range (< 2m)'),
                                        ),
                                      ],
                                      onChanged: (value) {
                                        setState(() {
                                          _filterMode = value!;
                                          _pointCloud = null;
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              if (_useMidasDepth)
                                const Padding(
                                  padding: EdgeInsets.all(8.0),
                                  child: Text(
                                    'Note: Process image in Depth Estimation first',
                                    style: TextStyle(fontSize: 12, color: Colors.orange),
                                  ),
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
                          onPanEnd: (details) {
                            // Add momentum/inertia effect if needed
                          },
                          child: CustomPaint(
                            painter: PointCloudPainter(
                              points: _pointCloud!,
                              rotationX: _rotationX,
                              rotationY: _rotationY,
                              zoom: _zoom,
                              offsetX: _offsetX,
                              offsetY: _offsetY,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                ),
                if (_pointCloud != null)
                  Column(
                    children: [
                      if (_statusMessage != null)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          color: Colors.black87,
                          child: Text(
                            _statusMessage!,
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        color: Colors.black54,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Column(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.add, color: Colors.white),
                                  onPressed: () {
                                    setState(() {
                                      _zoom = (_zoom * 1.2).clamp(0.1, 10.0);
                                    });
                                  },
                                ),
                                const Text('Zoom', style: TextStyle(color: Colors.white, fontSize: 10)),
                                IconButton(
                                  icon: const Icon(Icons.remove, color: Colors.white),
                                  onPressed: () {
                                    setState(() {
                                      _zoom = (_zoom / 1.2).clamp(0.1, 10.0);
                                    });
                                  },
                                ),
                              ],
                            ),
                            Column(
                              children: [
                                const Text('Drag to rotate', style: TextStyle(color: Colors.white, fontSize: 12)),
                                const SizedBox(height: 4),
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.refresh, size: 16),
                                  label: const Text('Reset View'),
                                  onPressed: () {
                                    setState(() {
                                      _rotationX = -0.5;
                                      _rotationY = 0.0;
                                      _zoom = 1.0;
                                      _offsetX = 0.0;
                                      _offsetY = 0.0;
                                    });
                                  },
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
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
  final double offsetX;
  final double offsetY;

  PointCloudPainter({
    required this.points,
    required this.rotationX,
    required this.rotationY,
    required this.zoom,
    required this.offsetX,
    required this.offsetY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2 + offsetX;
    final centerY = size.height / 2 + offsetY;
    final scale = math.min(size.width, size.height) * 0.3 * zoom;

    // Draw background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.black,
    );

    // Sort points by depth for correct rendering
    final sortedPoints = List<Point3D>.from(points);
    sortedPoints.sort((a, b) {
      final aZ = _rotateZ(a);
      final bZ = _rotateZ(b);
      return aZ.compareTo(bZ);
    });

    // Draw points with larger size for better visibility
    for (final point in sortedPoints) {
      // Apply rotation
      final rotated = _rotate3D(point);

      // Project to 2D
      final screenX = centerX + rotated.x * scale;
      final screenY = centerY - rotated.y * scale;

      // Skip points outside screen
      if (screenX < 0 || screenX > size.width || screenY < 0 || screenY > size.height) {
        continue;
      }

      // Calculate point size based on depth (closer = larger)
      final pointSize = math.max(1.5, 3.0 / (1.0 + rotated.z.abs()));

      // Draw point with slight glow effect
      final paint = Paint()
        ..color = Color.fromRGBO(point.r, point.g, point.b, 1.0)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(screenX, screenY), pointSize, paint);
    }

    // Draw coordinate axes for reference
    _drawAxes(canvas, centerX, centerY, scale);
  }

  void _drawAxes(Canvas canvas, double centerX, double centerY, double scale) {
    const axisLength = 0.2;
    
    // X axis (red)
    final xEnd = _rotate3D(Point3D(x: axisLength, y: 0, z: 0, r: 255, g: 0, b: 0));
    canvas.drawLine(
      Offset(centerX, centerY),
      Offset(centerX + xEnd.x * scale, centerY - xEnd.y * scale),
      Paint()..color = Colors.red..strokeWidth = 2,
    );
    
    // Y axis (green)
    final yEnd = _rotate3D(Point3D(x: 0, y: axisLength, z: 0, r: 0, g: 255, b: 0));
    canvas.drawLine(
      Offset(centerX, centerY),
      Offset(centerX + yEnd.x * scale, centerY - yEnd.y * scale),
      Paint()..color = Colors.green..strokeWidth = 2,
    );
    
    // Z axis (blue)
    final zEnd = _rotate3D(Point3D(x: 0, y: 0, z: axisLength, r: 0, g: 0, b: 255));
    canvas.drawLine(
      Offset(centerX, centerY),
      Offset(centerX + zEnd.x * scale, centerY - zEnd.y * scale),
      Paint()..color = Colors.blue..strokeWidth = 2,
    );
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
        oldDelegate.zoom != zoom ||
        oldDelegate.offsetX != offsetX ||
        oldDelegate.offsetY != offsetY;
  }
}
