import 'package:flutter/material.dart';

enum CustomerAuthMode { login, register }

class CustomerCredentials {
  const CustomerCredentials({
    required this.username,
    required this.password,
  });

  final String username;
  final String password;
}

Future<CustomerCredentials?> showCustomerAuthPage(
  BuildContext context, {
  required CustomerAuthMode mode,
}) {
  return Navigator.of(context).push<CustomerCredentials>(
    MaterialPageRoute(
      builder: (_) => CustomerAuthPage(mode: mode),
    ),
  );
}

class CustomerAuthPage extends StatefulWidget {
  const CustomerAuthPage({super.key, required this.mode});

  final CustomerAuthMode mode;

  @override
  State<CustomerAuthPage> createState() => _CustomerAuthPageState();
}

class _CustomerAuthPageState extends State<CustomerAuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool get _isRegister => widget.mode == CustomerAuthMode.register;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(
      CustomerCredentials(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF090909),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          onPressed: () {
                            FocusScope.of(context).unfocus();
                            Navigator.of(context).pop();
                          },
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121212),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _isRegister ? 'Register Account' : 'Login Account',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _isRegister
                                    ? 'Create a customer account to save remaining session time across devices.'
                                    : 'Login to restore saved session time and continue immediately.',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 24),
                              TextFormField(
                                controller: _usernameController,
                                textInputAction: TextInputAction.next,
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  labelText: 'Username',
                                  labelStyle: TextStyle(color: Colors.white70),
                                ),
                                validator: (value) {
                                  final username = value?.trim() ?? '';
                                  if (username.isEmpty) {
                                    return 'Username is required.';
                                  }
                                  if (username.length < 3) {
                                    return 'Minimum 3 characters.';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _passwordController,
                                obscureText: true,
                                textInputAction: _isRegister
                                    ? TextInputAction.next
                                    : TextInputAction.done,
                                onFieldSubmitted: (_) {
                                  if (!_isRegister) {
                                    _submit();
                                  }
                                },
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  labelText: 'Password',
                                  labelStyle: TextStyle(color: Colors.white70),
                                ),
                                validator: (value) {
                                  final password = value?.trim() ?? '';
                                  if (password.isEmpty) {
                                    return 'Password is required.';
                                  }
                                  if (password.length < 4) {
                                    return 'Minimum 4 characters.';
                                  }
                                  return null;
                                },
                              ),
                              if (_isRegister) ...[
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _confirmPasswordController,
                                  obscureText: true,
                                  textInputAction: TextInputAction.done,
                                  onFieldSubmitted: (_) => _submit(),
                                  style: const TextStyle(color: Colors.white),
                                  decoration: const InputDecoration(
                                    labelText: 'Confirm Password',
                                    labelStyle: TextStyle(color: Colors.white70),
                                  ),
                                  validator: (value) {
                                    if (value != _passwordController.text) {
                                      return 'Passwords do not match.';
                                    }
                                    return null;
                                  },
                                ),
                              ],
                              const SizedBox(height: 28),
                              ElevatedButton(
                                onPressed: _submit,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                ),
                                child: Text(_isRegister ? 'Register' : 'Login'),
                              ),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: () {
                                  FocusScope.of(context).unfocus();
                                  Navigator.of(context).pop();
                                },
                                child: Text(
                                  'Back',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
