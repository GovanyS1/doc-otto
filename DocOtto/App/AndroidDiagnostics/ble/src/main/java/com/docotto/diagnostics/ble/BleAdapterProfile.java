package com.docotto.diagnostics.ble;

import java.util.UUID;

/** Manufacturer-documented GATT settings; selected device is supplied separately. */
public final class BleAdapterProfile {
    public enum WriteMode { WITH_RESPONSE, WITHOUT_RESPONSE }
    public final UUID serviceUuid;
    public final UUID writeUuid;
    public final UUID notifyUuid;
    public final WriteMode writeMode;

    public BleAdapterProfile(UUID serviceUuid, UUID writeUuid, UUID notifyUuid, WriteMode writeMode) {
        if (serviceUuid == null || writeUuid == null || notifyUuid == null || writeMode == null) {
            throw new IllegalArgumentException("Explicit GATT UUIDs and write mode are required.");
        }
        this.serviceUuid = serviceUuid;
        this.writeUuid = writeUuid;
        this.notifyUuid = notifyUuid;
        this.writeMode = writeMode;
    }
}
