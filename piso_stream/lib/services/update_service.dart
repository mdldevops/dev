import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.latestVersion,
    required this.releaseNotes,
    required this.apkAssetName,
    required this.apkDownloadUrl,
    required this.updateAvailable,
  });

  final String currentVersion;
  final String currentBuildNumber;
  final String latestVersion;
  final String releaseNotes;
  final String apkAssetName;
  final String apkDownloadUrl;
  final bool updateAvailable;
}

class UpdateDownloadProgress {
  const UpdateDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

class UpdateServiceException implements Exception {
  const UpdateServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const String _latestReleaseUrl =
      'https://api.github.com/repos/mdldevops/pisostream_update/releases/latest';
  static const String _allowedDownloadPrefix =
      'https://github.com/mdldevops/pisostream_update/releases/download/';
  static const Duration _requestTimeout = Duration(seconds: 20);

  Future<AppUpdateInfo> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final response = await http
        .get(
          Uri.parse(_latestReleaseUrl),
          headers: const <String, String>{
            HttpHeaders.acceptHeader: 'application/vnd.github+json',
            HttpHeaders.userAgentHeader: 'PisoStream-Updater',
          },
        )
        .timeout(_requestTimeout);

    if (response.statusCode == 404) {
      throw const UpdateServiceException(
        'No update information is currently available.',
      );
    }
    if (response.statusCode == 403) {
      throw const UpdateServiceException(
        'Unable to contact the update server. Please try again later.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const UpdateServiceException('Unable to contact the update server.');
    }

    final Object decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const UpdateServiceException(
        'The update server returned invalid information.',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw const UpdateServiceException(
        'The update server returned invalid information.',
      );
    }

    final tagName = (decoded['tag_name'] ?? '').toString().trim();
    if (tagName.isEmpty) {
      throw const UpdateServiceException(
        'No update information is currently available.',
      );
    }

    final latestVersion = tagName.startsWith('v') || tagName.startsWith('V')
        ? tagName.substring(1)
        : tagName;
    final releaseNotes = (decoded['body'] ?? '').toString().trim();
    final assets = decoded['assets'];
    if (assets is! List) {
      throw const UpdateServiceException(
        'No APK was found in the latest release.',
      );
    }

    Map<String, dynamic>? apkAsset;
    for (final asset in assets) {
      if (asset is Map<String, dynamic> &&
          asset['name'].toString().toLowerCase().endsWith('.apk')) {
        apkAsset = asset;
        break;
      }
    }

    if (apkAsset == null) {
      throw const UpdateServiceException(
        'No APK was found in the latest release.',
      );
    }

    final apkDownloadUrl = (apkAsset['browser_download_url'] ?? '')
        .toString()
        .trim();
    if (!apkDownloadUrl.startsWith(_allowedDownloadPrefix)) {
      throw const UpdateServiceException(
        'The update package source is invalid.',
      );
    }

    return AppUpdateInfo(
      currentVersion: packageInfo.version,
      currentBuildNumber: packageInfo.buildNumber,
      latestVersion: latestVersion,
      releaseNotes: releaseNotes,
      apkAssetName: (apkAsset['name'] ?? 'PisoStream.apk').toString(),
      apkDownloadUrl: apkDownloadUrl,
      updateAvailable: compareSemanticVersions(
            latestVersion,
            packageInfo.version,
          ) >
          0,
    );
  }

  Future<File> downloadApk(
    AppUpdateInfo updateInfo, {
    required void Function(UpdateDownloadProgress progress) onProgress,
  }) async {
    if (!updateInfo.apkDownloadUrl.startsWith(_allowedDownloadPrefix)) {
      throw const UpdateServiceException('The update package source is invalid.');
    }

    final cacheDir = await getTemporaryDirectory();
    final updatesDir = Directory('${cacheDir.path}${Platform.pathSeparator}updates');
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }

    final apkFile = File(
      '${updatesDir.path}${Platform.pathSeparator}${updateInfo.apkAssetName}',
    );
    if (await apkFile.exists()) {
      await apkFile.delete();
    }

    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(updateInfo.apkDownloadUrl));
      request.headers[HttpHeaders.userAgentHeader] = 'PisoStream-Updater';
      final response = await client.send(request).timeout(_requestTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const UpdateServiceException('Unable to download the update.');
      }

      final totalBytes = response.contentLength;
      var receivedBytes = 0;
      sink = apkFile.openWrite();
      await for (final chunk in response.stream) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        onProgress(
          UpdateDownloadProgress(
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
          ),
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (!await apkFile.exists() || await apkFile.length() == 0) {
        throw const UpdateServiceException('Unable to download the update.');
      }

      return apkFile;
    } on UpdateServiceException {
      if (await apkFile.exists()) {
        await apkFile.delete();
      }
      rethrow;
    } catch (_) {
      if (await apkFile.exists()) {
        await apkFile.delete();
      }
      throw const UpdateServiceException('Unable to download the update.');
    } finally {
      await sink?.close();
      client.close();
    }
  }

  int compareSemanticVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    final maxLength = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var i = 0; i < maxLength; i++) {
      final leftValue = i < leftParts.length ? leftParts[i] : 0;
      final rightValue = i < rightParts.length ? rightParts[i] : 0;
      if (leftValue != rightValue) {
        return leftValue.compareTo(rightValue);
      }
    }
    return 0;
  }

  List<int> _versionParts(String version) {
    final core = version.split('-').first.split('+').first;
    return core
        .split('.')
        .map((part) => int.tryParse(part.trim()) ?? 0)
        .toList(growable: false);
  }
}
