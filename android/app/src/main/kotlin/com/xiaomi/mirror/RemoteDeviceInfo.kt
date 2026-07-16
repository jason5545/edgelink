package com.xiaomi.mirror

import android.os.Bundle
import android.os.Parcel
import android.os.Parcelable

class RemoteDeviceInfo() : Parcelable {
    private var bundle: Bundle = Bundle().apply {
        putString(KEY_PLATFORM, PLATFORM_ANDROID_PHONE)
        putInt(KEY_CONNECT_TYPE, CONNECT_TYPE_NONE)
    }

    private constructor(source: Bundle) : this() {
        bundle = Bundle(source)
    }

    private constructor(parcel: Parcel) : this(
        parcel.readBundle(RemoteDeviceInfo::class.java.classLoader) ?: Bundle()
    )

    val id: String?
        get() = bundle.getString(KEY_ID)

    val deviceId: String?
        get() = bundle.getString(KEY_DEVICE_ID)

    val displayName: String?
        get() = bundle.getString(KEY_DISPLAY_NAME)

    val platform: String?
        get() = bundle.getString(KEY_PLATFORM)

    val manufacturer: String?
        get() = bundle.getString(KEY_MANUFACTURER)

    val address: String?
        get() = bundle.getString(KEY_ADDRESS)

    val isMediaRelay: Int
        get() = bundle.getInt(KEY_IS_MEDIA_RELAY, MEDIA_RELAY_NOT_SUPPORT)

    val connectType: Int
        get() = bundle.getInt(KEY_CONNECT_TYPE, CONNECT_TYPE_NONE)

    fun getBundle(): Bundle = Bundle(bundle)

    override fun describeContents(): Int = 0

    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeBundle(bundle)
    }

    override fun toString(): String =
        "RemoteDeviceInfo(id=$id, deviceId=$deviceId, name=$displayName, " +
            "platform=$platform, manufacturer=$manufacturer, mediaRelay=$isMediaRelay, " +
            "connectType=$connectType)"

    companion object {
        const val MANUFACTURER_XIAOMI = "xiaomi"
        const val MANUFACTURER_OTHER = "other"
        const val PLATFORM_ANDROID_PAD = "AndroidPad"
        const val PLATFORM_ANDROID_PAD_CAR = "AndroidPadCar"
        const val PLATFORM_ANDROID_PHONE = "AndroidPhone"
        const val PLATFORM_WINDOWS = "Windows"
        const val CONNECT_TYPE_NONE = 0
        const val CONNECT_TYPE_BASIC = 1
        const val CONNECT_TYPE_ADVANCED = 2
        const val MEDIA_RELAY_ENABLED = 1
        const val MEDIA_RELAY_DISABLED = 0
        const val MEDIA_RELAY_NOT_SUPPORT = -1

        private const val KEY_ACCOUNT_STATUS = "account_status"
        private const val KEY_ADDRESS = "address"
        private const val KEY_APP_VERSION = "app_version"
        private const val KEY_BT_MAC = "bt_mac"
        private const val KEY_CAPABILITIES = "capabilities"
        private const val KEY_CONNECT_TYPE = "connect_type"
        private const val KEY_DESKTOP_SWITCH = "desktop_switch"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_DISPLAY_NAME = "display_name"
        private const val KEY_HANDOFF_SWITCH = "handoff_switch"
        private const val KEY_ID = "id"
        private const val KEY_IS_FLIP_STATE = "is_flip_state"
        private const val KEY_IS_LYRA = "is_lyra"
        private const val KEY_IS_MEDIA_RELAY = "is_media_relay"
        private const val KEY_IS_MIRROR_ENABLED = "is_mirror_enabled"
        private const val KEY_IS_SHOW_MIRROR = "is_show_mirror"
        private const val KEY_IS_SUBSCREEN_ENABLED = "is_subscreen_enabled"
        private const val KEY_IS_SUPPORT_ENABLE_MIRROR = "is_support_enable_mirror"
        private const val KEY_IS_SUPPORT_SEND_APP = "is_support_send_app"
        private const val KEY_IS_SUPPORT_SUB_SCREEN = "is_support_subscreen"
        private const val KEY_LAST_CONNECT_TIMESTAMP = "last_connect_timestamp"
        private const val KEY_MANUFACTURER = "manufacturer"
        private const val KEY_PLATFORM = "platform"
        private const val KEY_PRODUCT_TYPE = "product_type"
        private const val KEY_SN = "sn"

        @JvmField
        val CREATOR: Parcelable.Creator<RemoteDeviceInfo> =
            object : Parcelable.Creator<RemoteDeviceInfo> {
                override fun createFromParcel(parcel: Parcel): RemoteDeviceInfo =
                    RemoteDeviceInfo(parcel)

                override fun newArray(size: Int): Array<RemoteDeviceInfo?> =
                    arrayOfNulls(size)
            }
    }
}
