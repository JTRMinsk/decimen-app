import 'package:flutter/material.dart';

import 'receiver_screen.dart';
import 'sender_screen.dart';

/// The landing screen: pick a direction. Both sides are offline, one-way and
/// camera-to-screen — there is no pairing, no network, no handshake.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Decimen 光传')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              '明文光传，摄像头可读',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            _modeCard(
              context,
              icon: Icons.arrow_upward,
              title: '发送',
              subtitle: '选文件或粘贴文本，播放二维码流',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SenderScreen()),
              ),
            ),
            const SizedBox(height: 16),
            _modeCard(
              context,
              icon: Icons.qr_code_scanner,
              title: '接收',
              subtitle: '摄像头扫码，重组并校验后保存',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ReceiverScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        leading: Icon(icon, size: 40),
        title: Text(title, style: const TextStyle(fontSize: 20)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
