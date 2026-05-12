import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme_provider.dart';

class AllowedAppsPage extends StatefulWidget {
  const AllowedAppsPage({super.key});

  @override
  State<AllowedAppsPage> createState() => _AllowedAppsPageState();
}

class _AllowedAppsPageState extends State<AllowedAppsPage> {
  static const MethodChannel _channel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );
  static const String _prefsKey = 'allowed_app_packages';

  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedPackages = <String>{};

  List<_InstalledApp> _apps = const <_InstalledApp>[];
  bool _isLoading = true;
  String? _errorMessage;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
    _loadData();
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPackages = prefs.getStringList(_prefsKey) ?? <String>[];
      final result = await _channel.invokeMethod<List<dynamic>>(
        'getInstalledApps',
      );

      final apps =
          (result ?? <dynamic>[])
              .whereType<Map>()
              .map(
                (dynamic item) => _InstalledApp.fromMap(
                  Map<dynamic, dynamic>.from(item as Map),
                ),
              )
              .toList()
            ..sort(_sortApps);

      if (!mounted) {
        return;
      }

      setState(() {
        _selectedPackages
          ..clear()
          ..addAll(savedPackages);
        _apps = apps;
        _isLoading = false;
      });
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = error.message ?? 'Unable to load installed apps.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to load installed apps.';
      });
    }
  }

  int _sortApps(_InstalledApp a, _InstalledApp b) {
    final byName = a.appName.toLowerCase().compareTo(b.appName.toLowerCase());
    if (byName != 0) {
      return byName;
    }
    return a.packageName.toLowerCase().compareTo(b.packageName.toLowerCase());
  }

  void _handleSearchChanged() {
    setState(() {
      _query = _searchController.text.trim().toLowerCase();
    });
  }

  Future<void> _saveSelection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _selectedPackages.toList()..sort());

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_selectedPackages.length} app${_selectedPackages.length == 1 ? '' : 's'} added to whitelist.',
        ),
      ),
    );
  }

  List<_InstalledApp> get _filteredApps {
    if (_query.isEmpty) {
      return _apps;
    }

    return _apps.where((app) {
      return app.appName.toLowerCase().contains(_query) ||
          app.packageName.toLowerCase().contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filteredApps = _filteredApps;

    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        final colors = themeProvider.currentTheme;
        final surfaceColor = colors[1].withValues(alpha: 0.72);
        final borderColor = Colors.white.withValues(alpha: 0.14);

        return Scaffold(
          backgroundColor: colors[0],
          appBar: AppBar(
            backgroundColor: colors[1].withValues(alpha: 0.9),
            title: const Text('Allowed Apps'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _isLoading ? null : _loadData,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colors,
              ),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _searchController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search installed apps',
                          hintStyle: const TextStyle(color: Colors.white60),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.white70,
                          ),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: _searchController.clear,
                                  icon: const Icon(
                                    Icons.clear,
                                    color: Colors.white70,
                                  ),
                                ),
                          filled: true,
                          fillColor: surfaceColor,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: borderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Colors.tealAccent,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${_selectedPackages.length} selected',
                        style: Theme.of(
                          context,
                        ).textTheme.titleMedium?.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _buildBody(filteredApps, surfaceColor, borderColor),
                ),
              ],
            ),
          ),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colors,
              ),
            ),
            child: SafeArea(
              minimum: const EdgeInsets.all(16),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.teal.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _isLoading ? null : _saveSelection,
                icon: const Icon(Icons.check),
                label: const Text('Save Whitelist'),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(
    List<_InstalledApp> filteredApps,
    Color surfaceColor,
    Color borderColor,
  ) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.tealAccent),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.white),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: borderColor),
                ),
                onPressed: _loadData,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    if (filteredApps.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No installed apps matched your search.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: filteredApps.length,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final app = filteredApps[index];
        final isSelected = _selectedPackages.contains(app.packageName);

        return Card(
          color: surfaceColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: borderColor),
          ),
          child: CheckboxListTile(
            value: isSelected,
            activeColor: Colors.tealAccent,
            checkColor: Colors.black,
            onChanged: (value) {
              setState(() {
                if (value ?? false) {
                  _selectedPackages.add(app.packageName);
                } else {
                  _selectedPackages.remove(app.packageName);
                }
              });
            },
            title: Text(
              app.appName,
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              app.packageName,
              style: const TextStyle(color: Colors.white70),
            ),
            secondary: CircleAvatar(
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              child: ClipOval(
                child: app.iconBytes != null
                    ? Image.memory(
                        app.iconBytes!,
                        width: 28,
                        height: 28,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) {
                          return const Icon(
                            Icons.android,
                            color: Colors.white,
                            size: 20,
                          );
                        },
                      )
                    : const Icon(Icons.android, color: Colors.white, size: 20),
              ),
            ),
            controlAffinity: ListTileControlAffinity.trailing,
          ),
        );
      },
    );
  }
}

class _InstalledApp {
  const _InstalledApp({
    required this.appName,
    required this.packageName,
    this.iconBytes,
  });

  final String appName;
  final String packageName;
  final Uint8List? iconBytes;

  factory _InstalledApp.fromMap(Map<dynamic, dynamic> map) {
    return _InstalledApp(
      appName: (map['appName'] as String?)?.trim().isNotEmpty == true
          ? map['appName'] as String
          : (map['packageName'] as String? ?? 'Unknown App'),
      packageName: map['packageName'] as String? ?? '',
      iconBytes: map['icon'] is Uint8List ? map['icon'] as Uint8List : null,
    );
  }
}
