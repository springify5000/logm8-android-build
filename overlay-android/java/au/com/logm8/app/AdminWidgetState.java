package au.com.logm8.app;

import android.content.Context;
import android.content.SharedPreferences;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** Last known dashboard totals, persisted so the widget survives restarts. */
public class AdminWidgetState {

    static final String PREFS = "logm8_admin_widget";

    long users = -1;
    long paid = -1;
    long trial = -1;
    long activeToday = -1;
    long activeMonth = -1;
    long updatedAtMs = 0;
    String error = null;

    static AdminWidgetState load(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        AdminWidgetState s = new AdminWidgetState();
        s.users = p.getLong("users", -1);
        s.paid = p.getLong("paid", -1);
        s.trial = p.getLong("trial", -1);
        s.activeToday = p.getLong("activeToday", -1);
        s.activeMonth = p.getLong("activeMonth", -1);
        s.updatedAtMs = p.getLong("updatedAtMs", 0);
        s.error = p.getString("error", null);
        return s;
    }

    void save(Context context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong("users", users)
            .putLong("paid", paid)
            .putLong("trial", trial)
            .putLong("activeToday", activeToday)
            .putLong("activeMonth", activeMonth)
            .putLong("updatedAtMs", updatedAtMs)
            .putString("error", error)
            .apply();
    }

    String fmt(long v) {
        return v < 0 ? "--" : String.format(Locale.getDefault(), "%,d", v);
    }

    String formatTime(long ms) {
        return new SimpleDateFormat("HH:mm", Locale.getDefault()).format(new Date(ms));
    }
}
