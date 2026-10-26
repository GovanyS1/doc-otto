package com.docotto.diagnostics;

import java.io.IOException;

public interface DmeTransport extends AutoCloseable {
    void open() throws IOException, InterruptedException;
    byte[] request(DmeRequest request) throws IOException, InterruptedException;
    @Override void close();
}
