package com.docotto.diagnostics;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Immutable results. A failed scan throws instead of creating one of these. */
public final class Diagnostics {
    private Diagnostics() {}

    public static final class FaultRecord {
        public final String code;
        public final int rawStatus;
        public final int supportedStatus;

        FaultRecord(String code, int rawStatus, int supportedStatus) {
            this.code = code;
            this.rawStatus = rawStatus;
            this.supportedStatus = supportedStatus;
        }

        public List<String> statusLabels() {
            String[] labels = {
                "Test failed", "Failed this operating cycle", "Pending", "Confirmed",
                "Test not completed since clearing", "Test failed since clearing",
                "Test not completed this operating cycle", "Warning indicator requested"
            };
            List<String> result = new ArrayList<>();
            for (int bit = 0; bit < labels.length; bit++) {
                if ((supportedStatus & (1 << bit)) != 0) result.add(labels[bit]);
            }
            return Collections.unmodifiableList(result);
        }
    }

    public static final class FaultRead {
        public final int statusAvailability;
        public final int requestedStatusMask;
        public final List<FaultRecord> faults;

        FaultRead(int available, List<FaultRecord> faults) {
            this.statusAvailability = available;
            this.requestedStatusMask = 0x0C;
            this.faults = Collections.unmodifiableList(new ArrayList<>(faults));
        }

        public int evaluatedStatusMask() { return requestedStatusMask & statusAvailability; }
        public int unavailableStatusMask() { return requestedStatusMask & ~statusAvailability; }
    }

    public static final class EngineScan {
        public final long startedAtMillis;
        public final long finishedAtMillis;
        public final String targetLabel;
        public final String vin;
        public final String vinRejection;
        public final FaultRead faultRead;

        EngineScan(long start, long finish, String label, String vin,
                   String vinRejection, FaultRead faults) {
            this.startedAtMillis = start;
            this.finishedAtMillis = finish;
            this.targetLabel = label;
            this.vin = vin;
            this.vinRejection = vinRejection;
            this.faultRead = faults;
        }
    }

    public static final class WireEvent {
        public final long timeMillis;
        public final String direction;
        public final String text;

        WireEvent(String direction, String text) {
            this.timeMillis = System.currentTimeMillis();
            this.direction = direction;
            this.text = text;
        }
    }
}
