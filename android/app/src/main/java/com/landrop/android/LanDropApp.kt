package com.landrop.android

import android.app.Application

class LanDropApp : Application() {
    override fun onCreate() {
        super.onCreate()
        LanDropCore.init(this)
    }
}
