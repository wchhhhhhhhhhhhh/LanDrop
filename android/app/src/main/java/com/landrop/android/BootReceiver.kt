package com.landrop.android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.landrop.android.service.TransferService

/**
 * 开机 / 应用更新后把接收服务拉起来：
 * 手机重启不用手动打开 App，局域网里照样能往这台手机发文件。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                runCatching {
                    val service = Intent(context, TransferService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) {
                        context.startForegroundService(service)
                    } else {
                        context.startService(service)
                    }
                }
            }
        }
    }
}
