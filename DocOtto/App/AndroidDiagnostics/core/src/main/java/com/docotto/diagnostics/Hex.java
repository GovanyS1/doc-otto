package com.docotto.diagnostics;

final class Hex {
    private static final char[] DIGITS = "0123456789ABCDEF".toCharArray();
    private Hex() {}

    static String encode(byte[] bytes) {
        char[] chars = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            chars[2 * i] = DIGITS[(bytes[i] & 0xFF) >>> 4];
            chars[2 * i + 1] = DIGITS[bytes[i] & 15];
        }
        return new String(chars);
    }

    static byte[] decode(String text) throws DiagnosticException {
        String compact = text.replaceAll("\\s", "");
        if (compact.isEmpty() || compact.length() % 2 != 0 ||
                !compact.matches("[0-9a-fA-F]+")) {
            throw DiagnosticException.malformed("Invalid hexadecimal data.");
        }
        byte[] bytes = new byte[compact.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) Integer.parseInt(compact.substring(i * 2, i * 2 + 2), 16);
        }
        return bytes;
    }
}
