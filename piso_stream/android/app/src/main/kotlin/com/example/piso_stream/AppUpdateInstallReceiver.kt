package com.example.piso_stream

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller

class AppUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != MainActivity.ACTION_APP_UPDATE_INSTALL_STATUS) {
            return
        }

        val sessionId = intent.getIntExtra(MainActivity.EXTRA_APP_UPDATE_SESSION_ID, -1)
        if (sessionId < 0) {
            return
        }

        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE
        )
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        MainActivity.completeAppUpdateInstall(context, sessionId, status, message)
    }
}
