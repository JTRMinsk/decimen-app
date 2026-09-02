import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../protocol/format.dart';
import '../protocol/fountain.dart';
import '../protocol/progress.dart';
import '../protocol/protocol.dart';
import '../protocol/send_settings.dart';
import '../protocol/snippet.dart';

/// The receiver: camera → QR decode (MLKit, background) → fountain reassembly →
/// SHA-256 verify → save via SAF, or show a text snippet.
class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final MobileScannerController _controller = MobileScannerController(
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode],
    // Fountain frames change every tick. `noDuplicates` hashes the decoded
    // value and will skip the rest of the stream if ML Kit returns empty or
    // identical UTF-8 for binary payloads.
    detectionSpeed: DetectionSpeed.unrestricted,
    // Android defaults to 640×480, which cannot resolve a version-40 QR
    // (177 modules, the 2953-byte default). 1080p is the practical minimum.
    cameraResolution: const Size(1920, 1080),
  );

  LTDecoder? _decoder;
  String _streamKey = '';
  int _startMs = 0;
  bool _done = false;

  double _fraction = 0;
  String _progressText = '等待二维码…';
  String _etaText = '';
  String? _error;
  String? _verdictShown;
  int _emptyPayloads = 0;
  int _unusableFrames = 0;

  OpticalFile? _resultFile;
  String? _resultSnippet;
  String? _saveNote;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _controller.dispose();
    super.dispose();
  }

  Uint8List? _rawBytesOf(Barcode barcode) {
    final rb = barcode.rawDecodedBytes;
    if (rb is DecodedBarcodeBytes && rb.bytes.isNotEmpty) return rb.bytes;
    if (rb is DecodedVisionBarcodeBytes) {
      final decoded = rb.bytes;
      if (decoded != null && decoded.isNotEmpty) return decoded;
      if (rb.rawBytes.isNotEmpty) return rb.rawBytes;
    }
    // ignore: deprecated_member_use
    final legacy = barcode.rawBytes;
    if (legacy != null && legacy.isNotEmpty) return legacy;
    final rawValue = barcode.rawValue;
    if (rawValue != null && rawValue.isNotEmpty) {
      return Uint8List.fromList(latin1.encode(rawValue));
    }
    return null;
  }

  String? _verdictZh(FrameVerdict verdict) {
    switch (verdict) {
      case FrameVerdictOlderSender(:final version):
        return '对方发送的是旧版 Decimen 格式（v$version）。请更新发送端。';
      case FrameVerdictNewerSender(:final version):
        return '对方发送的是新版 Decimen 格式（v$version）。请更新本应用以接收。';
      case FrameVerdictUnsupportedFlags():
        return '该光流使用了当前版本无法读取的 Decimen 功能。请更新本应用。';
      default:
        return null;
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final bytes = _rawBytesOf(barcode);
      if (bytes == null) {
        _emptyPayloads++;
        if (_decoder == null && _verdictShown == null && _emptyPayloads == 8) {
          setState(() {
            _progressText =
                '扫到了二维码，但读不到二进制数据。请把发送端降到 $noSignalHintTxFps fps / $noSignalHintFrameBytes 字节。';
          });
        }
        continue;
      }
      _handleFrame(bytes);
    }
  }

  void _handleFrame(Uint8List bytes) {
    if (_done) return;
    final parsed = parseFrame(bytes);
    if (parsed == null) {
      final message = _verdictZh(classifyFrame(bytes));
      if (message != null && message != _verdictShown) {
        setState(() {
          _error = message;
          _verdictShown = message;
        });
      } else if (message == null && _decoder == null && _verdictShown == null) {
        _unusableFrames++;
        if (_unusableFrames == 12) {
          setState(() {
            _progressText =
                '扫到了二维码，但不是可解码的光传帧。请把网页发送端降到 $noSignalHintTxFps fps / $noSignalHintFrameBytes 字节后重试。';
          });
        }
      }
      return;
    }
    final header = parsed.header;
    if (_verdictShown != null) {
      _verdictShown = null;
      _error = null;
    }
    final identity = streamIdentity(header);
    if (_decoder == null || _streamKey != identity) {
      _decoder = LTDecoder(
          header.k, header.blockLen, header.sessionId, header.totalLen);
      _streamKey = identity;
      _startMs = DateTime.now().millisecondsSinceEpoch;
    }
    final decoder = _decoder!;
    decoder.addFrame(header.seq, parsed.block);
    _updateProgress(decoder);
    if (decoder.isComplete) {
      _finish(decoder.assemble()!, header.payloadFnv);
    }
  }

  void _updateProgress(LTDecoder decoder) {
    final elapsed =
        (DateTime.now().millisecondsSinceEpoch - _startMs) / 1000.0;
    final usefulFrames = decoder.framesNew - decoder.framesRedundant;
    final est = estimateTransferProgress(
        decoder.k, usefulFrames, elapsed, decoder.solvedCount);
    setState(() {
      _fraction = est.fraction;
      _progressText =
          '${(est.fraction * 100).toStringAsFixed(1)}% · ${decoder.solvedCount}/${decoder.k} 块 · ${decoder.framesNew} 帧';
      _etaText = est.etaSeconds == null
          ? '估算时间…'
          : '约 ${formatDuration(est.etaSeconds!)}';
    });
  }

  Future<void> _finish(Uint8List container, int payloadFnv) async {
    _done = true;
    await _controller.stop();
    final hashOk = fnv1a(container) == payloadFnv;
    if (!hashOk) {
      setState(() {
        _error = '光流校验和不匹配，请重试。';
        _fraction = 1;
      });
      return;
    }
    try {
      final file = unpackFile(container);
      if (!verifyFile(file)) {
        throw const FormatException('恢复的文件未通过 SHA-256 校验。');
      }
      if (isSnippet(file)) {
        setState(() {
          _resultSnippet = snippetText(file);
          _resultFile = null;
          _fraction = 1;
          _progressText = '100% · 文本已恢复';
        });
      } else {
        setState(() {
          _resultFile = file;
          _resultSnippet = null;
          _fraction = 1;
          _progressText = '100% · 文件已恢复';
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString().replaceFirst('FormatException: ', '');
        _fraction = 1;
      });
    }
  }

  Future<void> _saveFile() async {
    final file = _resultFile;
    if (file == null) return;
    final uri = await FilePicker.saveFile(
      fileName: file.name,
      bytes: file.bytes,
      mimeType: file.type,
      dialogTitle: '保存接收到的文件',
    );
    if (!mounted) return;
    setState(() {
      _saveNote = uri == null ? '已取消保存' : '已保存';
    });
  }

  void _reset() {
    setState(() {
      _decoder = null;
      _streamKey = '';
      _startMs = 0;
      _done = false;
      _fraction = 0;
      _progressText = '等待二维码…';
      _etaText = '';
      _error = null;
      _verdictShown = null;
      _emptyPayloads = 0;
      _unusableFrames = 0;
      _resultFile = null;
      _resultSnippet = null;
      _saveNote = null;
    });
    _controller.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('接收'),
        actions: [
          if (_done)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '重新接收',
              onPressed: _reset,
            ),
        ],
      ),
      body: _done ? _buildResult() : _buildScanner(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          onDetectError: (error, _) {
            if (_error == null) {
              setState(() => _error = '相机错误：$error');
            }
          },
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: Colors.black54,
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: _fraction,
                  backgroundColor: Colors.white24,
                ),
                const SizedBox(height: 8),
                Text(
                  _error ?? _progressText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _error == null ? Colors.white : Colors.redAccent,
                  ),
                ),
                if (_etaText.isNotEmpty)
                  Text(
                    _etaText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                const Text(
                  '明文光传，摄像头可读',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResult() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _reset,
                child: const Text('重新接收'),
              ),
            ],
          ),
        ),
      );
    }

    final file = _resultFile;
    final snippet = _resultSnippet;
    if (snippet != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('文本已收到',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('SHA-256 校验通过 ✓', style: TextStyle(color: Colors.green)),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SingleChildScrollView(child: Text(snippet)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy),
                    label: const Text('复制'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: snippet));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制')),
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _reset,
                    child: const Text('继续接收'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (file != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('传输完成！',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('${file.name} · ${formatBytes(file.bytes.length)} · SHA-256 校验通过 ✓'),
            const SizedBox(height: 16),
            if (file.type.startsWith('image/'))
              Expanded(
                child: Center(
                  child: Image.memory(file.bytes, fit: BoxFit.contain),
                ),
              )
            else
              Expanded(
                child: Center(
                  child: Text(
                    '已接收 ${file.name}',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            if (_saveNote != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_saveNote!, textAlign: TextAlign.center),
              ),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.save_alt),
                    label: Text('保存 ${file.name}'),
                    onPressed: _saveFile,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _reset,
                    child: const Text('继续接收'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
