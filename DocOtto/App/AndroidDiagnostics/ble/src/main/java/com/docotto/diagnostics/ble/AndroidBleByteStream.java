package com.docotto.diagnostics.ble;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothStatusCodes;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;

import com.docotto.diagnostics.AdapterByteStream;
import com.docotto.diagnostics.Deadline;
import com.docotto.diagnostics.DiagnosticException;

import java.io.IOException;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Single-session foreground BLE stream for Android API 26+.
 * Blocking methods must run on a worker. GATT callbacks use a private handler.
 * No device discovery, pairing UI, address guessing, or background service.
 */
@SuppressLint("MissingPermission")
public final class AndroidBleByteStream implements AdapterByteStream {
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private enum Stage { NEW, CONNECTING, DISCOVERING, SUBSCRIBING, READY, CLOSED }

    private static final class ReadEvent {
        final byte[] data;
        final IOException error;
        ReadEvent(byte[] data, IOException error) { this.data = data; this.error = error; }
    }

    private final Context context;
    private final BluetoothDevice selectedDevice;
    private final BleAdapterProfile profile;
    private final Object state = new Object();
    private final ReentrantLock operation = new ReentrantLock();
    private final CountDownLatch connectionReady = new CountDownLatch(1);
    private final LinkedBlockingQueue<ReadEvent> incoming = new LinkedBlockingQueue<>();
    private HandlerThread callbackThread;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic writeCharacteristic;
    private BluetoothGattCharacteristic notifyCharacteristic;
    private BluetoothGattDescriptor notificationDescriptor;
    private CountDownLatch writeComplete;
    private IOException failure;
    private boolean started;
    private boolean closed;
    private boolean ready;
    private int queuedBytes;
    private Stage stage = Stage.NEW;

    public AndroidBleByteStream(Context context, BluetoothDevice selectedDevice,
                                BleAdapterProfile profile) {
        if (context == null || selectedDevice == null || profile == null) {
            throw new IllegalArgumentException("Context, selected BLE device, and profile are required.");
        }
        this.context = context.getApplicationContext();
        this.selectedDevice = selectedDevice;
        this.profile = profile;
    }

    @Override public void connect(long timeoutMillis) throws IOException, InterruptedException {
        requireWorker();
        enter();
        try {
            checkInterrupted();
            Deadline deadline = Deadline.afterMillis(timeoutMillis);
            synchronized (state) {
                if (started || closed) throw DiagnosticException.disconnected();
                started = true;
                if (Build.VERSION.SDK_INT >= 31 &&
                        context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)
                                != PackageManager.PERMISSION_GRANTED) {
                    throw adapterError("Bluetooth connection permission has not been granted.");
                }
                BluetoothManager manager = (BluetoothManager)
                        context.getSystemService(Context.BLUETOOTH_SERVICE);
                BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
                if (adapter == null || !adapter.isEnabled()) {
                    throw adapterError("Bluetooth is unavailable or powered off.");
                }
                callbackThread = new HandlerThread("DocOtto-BLE");
                callbackThread.start();
                stage = Stage.CONNECTING;
                gatt = selectedDevice.connectGatt(context, false, callbacks,
                        BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK,
                        new Handler(callbackThread.getLooper()));
                if (gatt == null) throw adapterError("Android could not create the GATT connection.");
            }
            if (!connectionReady.await(deadline.remainingMillis(), TimeUnit.MILLISECONDS)) {
                throw DiagnosticException.timeout();
            }
            checkInterrupted();
            synchronized (state) {
                checkFailure();
                if (!ready) throw adapterError("BLE notifications are not ready.");
            }
        } catch (SecurityException error) {
            DiagnosticException wrapped = adapterError("Bluetooth permission was denied or revoked.");
            terminate(wrapped);
            throw wrapped;
        } catch (IOException | InterruptedException error) {
            terminate(error);
            throw error;
        } catch (RuntimeException error) {
            terminate(error);
            throw error;
        } finally {
            operation.unlock();
        }
    }

    @Override public void write(byte[] bytes, long timeoutMillis)
            throws IOException, InterruptedException {
        requireWorker();
        enter();
        try {
            checkInterrupted();
            Deadline deadline = Deadline.afterMillis(timeoutMillis);
            CountDownLatch completion = new CountDownLatch(1);
            synchronized (state) {
                checkFailure();
                if (!ready || gatt == null) throw DiagnosticException.disconnected();
                // ELM read requests are 17 ASCII bytes including CR. Stay inside
                // the baseline ATT payload; no MTU negotiation/chunking is needed.
                if (bytes == null || bytes.length == 0 || bytes.length > 20) {
                    throw new DiagnosticException(DiagnosticException.Kind.INVALID_CONFIGURATION,
                            "One BLE write must contain 1...20 bytes.");
                }
                if (writeComplete != null) throw adapterError("A GATT write is already pending.");
                writeComplete = completion;
                int mode = profile.writeMode == BleAdapterProfile.WriteMode.WITH_RESPONSE
                        ? BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                        : BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE;
                if (!startWrite(gatt, writeCharacteristic, bytes.clone(), mode)) {
                    throw adapterError("Android rejected the characteristic write.");
                }
            }
            if (!completion.await(deadline.remainingMillis(), TimeUnit.MILLISECONDS)) {
                throw DiagnosticException.timeout();
            }
            checkInterrupted();
            synchronized (state) { checkFailure(); }
        } catch (SecurityException error) {
            DiagnosticException wrapped = adapterError("Bluetooth permission was denied or revoked.");
            terminate(wrapped);
            throw wrapped;
        } catch (IOException | InterruptedException error) {
            terminate(error);
            throw error;
        } catch (RuntimeException error) {
            terminate(error);
            throw error;
        } finally {
            operation.unlock();
        }
    }

    @Override public byte[] read(long timeoutMillis) throws IOException, InterruptedException {
        requireWorker();
        try {
            checkInterrupted();
            Deadline deadline = Deadline.afterMillis(timeoutMillis);
            synchronized (state) { checkFailure(); }
            ReadEvent event = incoming.poll(deadline.remainingMillis(), TimeUnit.MILLISECONDS);
            if (event == null) throw DiagnosticException.timeout();
            return consume(event);
        } catch (IOException | InterruptedException error) {
            terminate(error);
            throw error;
        }
    }

    @Override public byte[] poll() throws IOException {
        synchronized (state) { checkFailure(); }
        ReadEvent event = incoming.poll();
        return event == null ? null : consume(event);
    }

    private byte[] consume(ReadEvent event) throws IOException {
        synchronized (state) {
            checkFailure();
            if (event.error != null) throw event.error;
            queuedBytes -= event.data.length;
            return event.data;
        }
    }

    private void receive(BluetoothGatt source, BluetoothGattCharacteristic characteristic, byte[] bytes) {
        synchronized (state) {
            if (closed || source != gatt || characteristic != notifyCharacteristic ||
                    (stage != Stage.SUBSCRIBING && stage != Stage.READY)) return;
            if (bytes == null) { terminate(adapterError("BLE notification had no value.")); return; }
            if (bytes.length == 0) return;
            if (queuedBytes + bytes.length > 32768) {
                terminate(adapterError("BLE notification buffer overflow."));
                return;
            }
            byte[] copy = bytes.clone();
            queuedBytes += copy.length;
            incoming.offer(new ReadEvent(copy, null));
        }
    }

    private final BluetoothGattCallback callbacks = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt source, int status, int newState) {
            synchronized (state) {
                if (closed || source != gatt) return;
                if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                    terminate(adapterError("GATT disconnected (status " + status + ")."));
                    return;
                }
                if (newState == BluetoothProfile.STATE_CONNECTED && stage == Stage.CONNECTING) {
                    stage = Stage.DISCOVERING;
                    try {
                        if (!source.discoverServices()) terminate(adapterError("Service discovery could not start."));
                    } catch (SecurityException error) {
                        terminate(adapterError("Bluetooth permission was revoked."));
                    }
                }
            }
        }

        @Override public void onServicesDiscovered(BluetoothGatt source, int status) {
            synchronized (state) {
                if (closed || source != gatt || stage != Stage.DISCOVERING) return;
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    terminate(adapterError("BLE service discovery failed."));
                    return;
                }
                BluetoothGattService service = source.getService(profile.serviceUuid);
                if (service == null) { terminate(adapterError("Configured BLE service was not found.")); return; }
                writeCharacteristic = service.getCharacteristic(profile.writeUuid);
                notifyCharacteristic = service.getCharacteristic(profile.notifyUuid);
                int property = profile.writeMode == BleAdapterProfile.WriteMode.WITH_RESPONSE
                        ? BluetoothGattCharacteristic.PROPERTY_WRITE
                        : BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE;
                if (writeCharacteristic == null || notifyCharacteristic == null ||
                        (writeCharacteristic.getProperties() & property) == 0) {
                    terminate(adapterError("Configured BLE characteristics/write mode are unavailable."));
                    return;
                }
                int notifyProperties = notifyCharacteristic.getProperties();
                boolean notifications = (notifyProperties & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0;
                boolean indications = (notifyProperties & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0;
                notificationDescriptor = notifyCharacteristic.getDescriptor(CCCD);
                if ((!notifications && !indications) || notificationDescriptor == null) {
                    terminate(adapterError("Notification characteristic or CCCD is unavailable."));
                    return;
                }
                try {
                    if (!source.setCharacteristicNotification(notifyCharacteristic, true)) {
                        terminate(adapterError("Android rejected notification registration."));
                        return;
                    }
                    byte[] value = notifications ? BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                            : BluetoothGattDescriptor.ENABLE_INDICATION_VALUE;
                    stage = Stage.SUBSCRIBING;
                    if (!startDescriptorWrite(source, notificationDescriptor, value)) {
                        terminate(adapterError("Android rejected the CCCD write."));
                    }
                } catch (SecurityException error) {
                    terminate(adapterError("Bluetooth permission was revoked."));
                }
            }
        }

        @Override public void onDescriptorWrite(BluetoothGatt source, BluetoothGattDescriptor descriptor, int status) {
            synchronized (state) {
                if (closed || source != gatt || descriptor != notificationDescriptor ||
                        stage != Stage.SUBSCRIBING) return;
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    terminate(adapterError("BLE notification subscription failed."));
                    return;
                }
                ready = true;
                stage = Stage.READY;
                connectionReady.countDown();
            }
        }

        @Override public void onCharacteristicWrite(BluetoothGatt source,
                                                    BluetoothGattCharacteristic characteristic, int status) {
            synchronized (state) {
                if (closed || source != gatt || characteristic != writeCharacteristic || writeComplete == null) return;
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    terminate(adapterError("GATT write failed (status " + status + ")."));
                    return;
                }
                CountDownLatch completion = writeComplete;
                writeComplete = null;
                completion.countDown();
            }
        }

        @Override public void onCharacteristicChanged(BluetoothGatt source,
                                                      BluetoothGattCharacteristic characteristic, byte[] value) {
            receive(source, characteristic, value);
        }

        @SuppressWarnings("deprecation")
        @Override public void onCharacteristicChanged(BluetoothGatt source,
                                                      BluetoothGattCharacteristic characteristic) {
            if (Build.VERSION.SDK_INT < 33) receive(source, characteristic, characteristic.getValue());
        }
    };

    @SuppressWarnings("deprecation")
    private static boolean startWrite(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic,
                                      byte[] bytes, int mode) {
        if (Build.VERSION.SDK_INT >= 33) {
            return gatt.writeCharacteristic(characteristic, bytes, mode) == BluetoothStatusCodes.SUCCESS;
        }
        characteristic.setWriteType(mode);
        return characteristic.setValue(bytes) && gatt.writeCharacteristic(characteristic);
    }

    @SuppressWarnings("deprecation")
    private static boolean startDescriptorWrite(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, byte[] value) {
        if (Build.VERSION.SDK_INT >= 33) {
            return gatt.writeDescriptor(descriptor, value.clone()) == BluetoothStatusCodes.SUCCESS;
        }
        return descriptor.setValue(value.clone()) && gatt.writeDescriptor(descriptor);
    }

    private void enter() throws DiagnosticException {
        if (operation.isHeldByCurrentThread() || !operation.tryLock()) {
            throw new DiagnosticException(DiagnosticException.Kind.BUSY, "Another BLE operation is in progress.");
        }
    }

    private void checkFailure() throws IOException {
        if (failure != null) throw failure;
        if (closed) throw DiagnosticException.disconnected();
    }

    private static void requireWorker() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            throw new IllegalStateException("Run diagnostic I/O on a worker thread.");
        }
    }

    private static void checkInterrupted() throws InterruptedException {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedException("BLE operation cancelled.");
    }

    private static DiagnosticException adapterError(String message) {
        return new DiagnosticException(DiagnosticException.Kind.ADAPTER, message);
    }

    private void terminate(Exception reason) {
        synchronized (state) {
            if (closed) return;
            closed = true;
            stage = Stage.CLOSED;
            ready = false;
            failure = reason instanceof IOException ? (IOException) reason : DiagnosticException.disconnected();
            incoming.clear();
            queuedBytes = 0;
            incoming.offer(new ReadEvent(null, failure));
            connectionReady.countDown();
            if (writeComplete != null) { writeComplete.countDown(); writeComplete = null; }
            BluetoothGatt connection = gatt;
            gatt = null;
            if (connection != null) {
                try { connection.disconnect(); } catch (SecurityException ignored) { /* Permission was revoked. */ }
                try { connection.close(); } catch (SecurityException ignored) { /* Finish local cleanup. */ }
            }
            writeCharacteristic = null;
            notifyCharacteristic = null;
            notificationDescriptor = null;
            if (callbackThread != null) { callbackThread.quitSafely(); callbackThread = null; }
        }
    }

    @Override public void close() { terminate(DiagnosticException.disconnected()); }
}
