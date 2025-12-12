import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:archive/archive_io.dart';
import 'package:intl/intl.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<Directory> _sessions = [];
  bool _loading = true;

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
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    }
    setState(() {
      _loading = false;
    });
  }

  Future<void> _exportSession(Directory sessionDir) async {
    try {
      // Create zip in temp directory
      final tempDir = await getTemporaryDirectory();
      final sessionName = sessionDir.path.split(Platform.pathSeparator).last;
      final zipFile = File('${tempDir.path}/$sessionName.zip');
      
      if (await zipFile.exists()) {
        await zipFile.delete();
      }

      // Create the archive manually to ensure all files are included
      final archive = Archive();
      final files = sessionDir.listSync();
      
      if (files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No files to export in this session')),
          );
        }
        return;
      }

      for (var file in files) {
        if (file is File) {
          final filename = file.path.split(Platform.pathSeparator).last;
          final bytes = await file.readAsBytes();
          final archiveFile = ArchiveFile(filename, bytes.length, bytes);
          archive.addFile(archiveFile);
        }
      }

      // Add README with instructions
      final readmeContent = '''
Session Export Data
===================

Files:
- *.jpg: RGB Images
- depth_*.bin: Raw Depth Maps (16-bit unsigned integer, millimeters)
- captures.json: Metadata including timestamps and pose matrices.

Pose Data:
The 'relativePose' in captures.json is a 4x4 transformation matrix (column-major) representing the Camera's position relative to the Anchor (Stick).

Depth Data:
The .bin files contain raw depth values. Each pixel is a 16-bit integer representing distance in millimeters.
Resolution depends on the device (e.g., 160x120 or 640x360).

Python Example to Read Data:
----------------------------
import json
import numpy as np
import os

with open('captures.json', 'r') as f:
    data = json.load(f)

for capture in data:
    # Pose
    pose = np.array(capture['relativePose']).reshape((4,4)).T
    print(f"Timestamp: {capture['timestamp']}")
    print("Pose:\\n", pose)
    
    # Depth
    depth_file = f"depth_{capture['timestamp']}.bin"
    if os.path.exists(depth_file):
        depth_data = np.fromfile(depth_file, dtype=np.uint16)
        print(f"Depth pixels: {len(depth_data)}")
''';
      archive.addFile(ArchiveFile('README.txt', readmeContent.length, readmeContent.codeUnits));

      // Encode the archive
      final encoder = ZipEncoder();
      final zipBytes = encoder.encode(archive);
      
      // Write to disk
      await zipFile.writeAsBytes(zipBytes);

      await Share.shareXFiles([XFile(zipFile.path)], text: 'Export Session Data');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gallery')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? const Center(child: Text('No sessions found'))
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final dir = _sessions[index];
                    final name = dir.path.split(Platform.pathSeparator).last;
                    final date = DateTime.fromMillisecondsSinceEpoch(
                        int.tryParse(name.split('_').last) ?? 0);
                    final formattedDate = DateFormat('yyyy-MM-dd HH:mm').format(date);
                    
                    return ListTile(
                      title: Text('Session: $formattedDate'),
                      subtitle: FutureBuilder<int>(
                        future: dir.list().length.then((_) => dir.listSync().where((e) => e.path.endsWith('.jpg')).length),
                        builder: (context, snapshot) {
                          return Text('${snapshot.data ?? 0} images');
                        },
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.share),
                        onPressed: () => _exportSession(dir),
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => SessionDetailScreen(sessionDir: dir),
                          ),
                        );
                      },
                    );
                  },
                ),
    );
  }
}

class SessionDetailScreen extends StatelessWidget {
  final Directory sessionDir;

  const SessionDetailScreen({super.key, required this.sessionDir});

  @override
  Widget build(BuildContext context) {
    final files = sessionDir.listSync()
        .where((e) => e.path.endsWith('.jpg'))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Session Images')),
      body: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: files.length,
        itemBuilder: (context, index) {
          return Image.file(files[index] as File, fit: BoxFit.cover);
        },
      ),
    );
  }
}
