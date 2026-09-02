import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../protocol/format.dart';
import '../protocol/fountain.dart';
import '../protocol/frame_capacity.dart';
import '../protocol/protocol.dart';
import '../protocol/send_settings.dart';
import '../protocol/snippet.dart';
import 'mime_types.dart';
import 'pack_background.dart';
import 'qr_encoder.dart';
import 'qr_painter.dart';

/// The sender: pick a file (≤64 MB) or paste text, then play an endless
/// fountain-coded QR stream that any Decimen receiver — the web page or this
/// app — can decode.
class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  final Random _random = Random();
  final TextEditingController _textController = TextEditingController();

  bool _isFile = true;
  int _txFps = defaultTxFps;
  int _frameBytes = defaultFrameBytes;

  bool _streaming = false;
  bool _fullscreen = false;
  String _status = '选择文件或粘贴文本开始';
  String? _error;

  LTEncoder? _encoder;
  FrameHeader? _header;
  int _nextSeq = 0;
  int _framesSent = 0;
  QrMatrix? _matrix;
  Timer? _timer;
  String _sendingName = '';

  @override
  void dispose() {
    _stopStream();
    _textController.dispose();
    super.dispose();
  }

  void _setStatus(String message) {
    setState(() {
      _status = message;
      _error = null;
    });
  }

  void _showError(String message) {
    _stopStream();
    setState(() {
      _error = message;
      _streaming = false;
      _matrix = null;
    });
  }

  void _stopStream() {
    _timer?.cancel();
    _timer = null;
    if (_streaming) WakelockPlus.disable();
    _streaming = false;
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFile(
      dialogTitle: '选择要发送的文件（≤ $maxFileLabel）',
    );
    if (result == null) return;
    _setStatus('正在准备 ${result.name}…');
    final bytes = await result.readAsBytes();
    if (bytes.isEmpty) {
      _showError('${result.name} 是空文件，没有可发送的内容。');
      return;
    }
    if (bytes.length > maxFileBytes) {
      _showError('${result.name} 是 ${formatBytes(bytes.length)}，超过 $maxFileLabel 限制。');
      return;
    }
    await _packAndStream(
      result.name,
      mimeTypeForName(result.name),
      bytes,
    );
  }

  Future<void> _sendSnippet() async {
    final text = _textController.text;
    if (text.trim().isEmpty) {
      _showError('请先粘贴或输入要发送的文本。');
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > maxSnippetBytes) {
      _showError('文本片段限制在 $maxSnippetLabel。');
      return;
    }
    _setStatus('正在准备文本片段…');
    await _packAndStream(snippetFileName, snippetMediaType, bytes);
  }

  Future<void> _packAndStream(
    String name,
    String type,
    Uint8List bytes,
  ) async {
    try {
      final packed = await packFileInBackground(name, type, bytes);
      await _startStream(name, packed);
    } catch (e) {
      _showError(e.toString().replaceFirst('FormatException: ', ''));
    }
  }

  Future<void> _startStream(String name, PackedOpticalFile packed) async {
    final blockLen = blockLength(_frameBytes);
    if (!fitsInOneStream(packed.container.length, _frameBytes)) {
      final suggestion = smallestSufficientFrameSize(
            packed.container.length,
            frameBytesOptions,
          ) ??
          minimumFrameBytes(packed.container.length);
      _showError(
        '${formatBytes(packed.container.length)} 在 $_frameBytes 字节/帧下需要 '
        '${sourceBlockCount(packed.container.length, _frameBytes)} 个块，'
        '而一帧最多只能编号 $maxSourceBlocks 个。'
        '请把“字节/帧”提高到 $suggestion 或更高。',
      );
      return;
    }

    _stopStream();
    final sessionId = (_random.nextInt(0xffff) + 1) & 0xffff;
    final encoder = LTEncoder(packed.container, blockLen, sessionId);
    final header = FrameHeader(
      sessionId: sessionId,
      seq: 0,
      k: encoder.k,
      blockLen: blockLen,
      totalLen: packed.container.length,
      payloadFnv: fnv1a(packed.container),
      flags: 0,
    );

    setState(() {
      _encoder = encoder;
      _header = header;
      _nextSeq = 0;
      _framesSent = 0;
      _matrix = null;
      _streaming = true;
      _error = null;
      _sendingName = name;
      _status =
          '正在发送 $name · K=${encoder.k} · ${formatBytes(packed.container.length)}';
    });

    WakelockPlus.enable();
    final intervalUs = (1000000 / _txFps).round();
    _timer = Timer.periodic(Duration(microseconds: intervalUs), _tick);
    _tick(_timer!);
  }

  void _tick(Timer timer) {
    final encoder = _encoder;
    final header = _header;
    if (encoder == null || header == null || !_streaming) return;
    final seq = _nextSeq++;
    final frame = packFrame(
      FrameHeader(
        sessionId: header.sessionId,
        seq: seq,
        k: header.k,
        blockLen: header.blockLen,
        totalLen: header.totalLen,
        payloadFnv: header.payloadFnv,
        flags: header.flags,
      ),
      encoder.encode(seq),
    );
    final matrix = encodeQrMatrix(frame);
    setState(() {
      _matrix = matrix;
      _framesSent = seq + 1;
    });
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('发送'),
        actions: [
          if (_streaming)
            IconButton(
              icon: const Icon(Icons.stop),
              tooltip: '停止',
              onPressed: () {
                _stopStream();
                setState(() {
                  _matrix = null;
                  _status = '选择文件或粘贴文本开始';
                });
              },
            ),
        ],
      ),
      body: Column(
        children: [
          if (!_fullscreen) _buildSettings(),
          Expanded(
            child: GestureDetector(
              onTap: _toggleFullscreen,
              child: Container(
                color: Colors.white,
                width: double.infinity,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(12),
                child: _matrix == null
                    ? const Text('点击选择内容后，二维码将在此显示',
                        style: TextStyle(color: Colors.grey))
                    : AspectRatio(
                        aspectRatio: 1,
                        child: CustomPaint(
                          painter: QrPainter(
                            modules: _matrix!.modules,
                            moduleCount: _matrix!.moduleCount,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          if (!_fullscreen) _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildSettings() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('文件')),
              ButtonSegment(value: false, label: Text('文本')),
            ],
            selected: {_isFile},
            onSelectionChanged: _streaming
                ? null
                : (selection) => setState(() => _isFile = selection.first),
          ),
          const SizedBox(height: 12),
          if (_isFile)
            OutlinedButton.icon(
              icon: const Icon(Icons.attach_file),
              label: Text(_streaming ? '正在发送 $_sendingName' : '选择文件（≤ $maxFileLabel）'),
              onPressed: _streaming ? null : _pickFile,
            )
          else
            TextField(
              controller: _textController,
              maxLines: 3,
              enabled: !_streaming,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: '要发送的文本（≤ $maxSnippetLabel）',
              ),
            ),
          if (!_isFile) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.send),
              label: const Text('发送文本'),
              onPressed: _streaming ? null : _sendSnippet,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('帧率'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _txFps,
                items: txFpsOptions
                    .map((f) => DropdownMenuItem(value: f, child: Text('$f fps')))
                    .toList(),
                onChanged: _streaming
                    ? null
                    : (v) => setState(() => _txFps = v ?? _txFps),
              ),
              const SizedBox(width: 24),
              const Text('字节/帧'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _frameBytes,
                items: frameBytesOptions
                    .map((b) =>
                        DropdownMenuItem(value: b, child: Text('$b')))
                    .toList(),
                onChanged: _streaming
                    ? null
                    : (v) => setState(() => _frameBytes = v ?? _frameBytes),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        children: [
          if (_error != null)
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            )
          else
            Text(
              _streaming ? '已发送 $_framesSent 帧 · 点击二维码全屏' : _status,
              textAlign: TextAlign.center,
              style: TextStyle(color: _streaming ? Colors.black : Colors.grey),
            ),
          const Text('明文光传，摄像头可读', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }
}
