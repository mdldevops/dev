import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/admin_pin_service.dart';
import 'settings.dart';
import 'theme_provider.dart';

class PasscodeScreen extends StatefulWidget {
  const PasscodeScreen({super.key});

  @override
  State<PasscodeScreen> createState() => PasscodeScreenState();
}

class PasscodeScreenState extends State<PasscodeScreen> {
  String _enteredPasscode = "";
  final int _maxDigits = 6;
  bool _isValidating = false;

  void _onKeyPressed(String digit) {
    if (_enteredPasscode.length < _maxDigits) {
      setState(() {
        _enteredPasscode += digit;

        // Check if finished
        if (_enteredPasscode.length == _maxDigits) {
          _validatePasscode();
        }
      });
    }
  }

  Future<void> _validatePasscode() async {
    if (_isValidating) {
      return;
    }

    setState(() {
      _isValidating = true;
    });

    try {
      final isValid = await AdminPinService.verifyPin(_enteredPasscode);
      if (!mounted) {
        return;
      }

      if (isValid) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => ChangeNotifierProvider.value(
              value: Provider.of<ThemeProvider>(context, listen: false),
              child: const SettingsPage(),
            ),
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Wrong passcode"),
          duration: Duration(seconds: 1),
          backgroundColor: Colors.redAccent,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (!mounted) {
        return;
      }

      setState(() {
        _isValidating = false;
        _enteredPasscode = "";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    final bool isTablet = size.shortestSide > 600;
    final double buttonSize = isTablet ? 100 : 80;
    final themeProvider = context.watch<ThemeProvider>();
    final colors = themeProvider.currentTheme;
    final panelColor = colors[1].withValues(alpha: 0.76);

    return Scaffold(
      backgroundColor: colors[0],
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
          ),
        ),
        child: SafeArea(
          minimum: EdgeInsets.only(bottom: bottomInset > 0 ? bottomInset : 16),
          child: SingleChildScrollView(
            child: Container(
              constraints: BoxConstraints(
                minHeight:
                    size.height -
                    MediaQuery.of(context).padding.top -
                    MediaQuery.of(context).padding.bottom,
              ),
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.08),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: const Icon(
                          Icons.admin_panel_settings,
                          color: Colors.tealAccent,
                          size: 42,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        "Enter Passcode",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        "Use the admin PIN to open settings",
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 30),
                      _buildPasscodeIndicators(),
                    ],
                  ),

                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 28),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: panelColor,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: isTablet ? 500 : 400,
                      ),
                      child: _buildNumberPad(buttonSize),
                    ),
                  ),

                  Column(
                    children: [
                      TextButton(
                        onPressed: () => setState(() => _enteredPasscode = ""),
                        child: const Text(
                          "Reset passcode",
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4, right: 4),
                          child: TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.08,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
                              ),
                            ),
                            child: const Text("Cancel"),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPasscodeIndicators() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_maxDigits, (index) {
        bool isFilled = index < _enteredPasscode.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isFilled ? Colors.tealAccent : Colors.white54,
              width: 1.5,
            ),
            color: isFilled
                ? Colors.tealAccent.withValues(alpha: 0.9)
                : Colors.transparent,
            boxShadow: isFilled
                ? [
                    BoxShadow(
                      color: Colors.tealAccent.withValues(alpha: 0.35),
                      blurRadius: 10,
                    ),
                  ]
                : null,
          ),
        );
      }),
    );
  }

  Widget _buildNumberPad(double buttonSize) {
    return Column(
      children: [
        for (var row in [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
          [null, '0', null],
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: row.map((val) {
                if (val == null) return SizedBox(width: buttonSize);
                return _buildButton(val, buttonSize);
              }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildButton(String number, double size) {
    return InkWell(
      onTap: _isValidating ? null : () => _onKeyPressed(number),
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.06),
          border: Border.all(color: Colors.white24, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Text(
          number,
          style: TextStyle(
            fontSize: size * 0.4,
            color: Colors.white,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
