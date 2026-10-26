package com.docotto.diagnostics;

import java.io.IOException;

public interface AdapterCommandChannel extends AutoCloseable {
    void connect() throws IOException, InterruptedException;
    String command(String text) throws IOException, InterruptedException;
    @Override void close();
}
