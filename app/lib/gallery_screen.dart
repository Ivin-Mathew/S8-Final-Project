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
      final zipFile = File('${sessionDir.path}.zip');
      var encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      encoder.addDirectory(sessionDir);
      encoder.close();

      await Share.shareXFiles([XFile(zipFile.path)], text: 'Export Session');
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
                        future: dir.list().length,
                        builder: (context, snapshot) {
                          return Text('${snapshot.data ?? 0} files');
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
