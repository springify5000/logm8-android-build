package au.com.logm8.app;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.annotation.NonNull;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.TimeZone;

/**
 * Fetches the owner dashboard totals for the home-screen widget.
 *
 * The web app (running inside the WebView) stores the signed-in user's Firebase refresh token
 * in Capacitor Preferences under {@code logm8_widget_auth}. This worker exchanges it for an
 * ID token and calls the same callable Cloud Function the admin page uses. Non-admin accounts
 * get "permission-denied" and the widget says so.
 */
public class AdminWidgetWorker extends Worker {

    private static final String AUTH_KEY = "logm8_widget_auth";
    private static final String CAPACITOR_PREFS = "CapacitorStorage";
    private static final String TOKEN_URL = "https://securetoken.googleapis.com/v1/token?key=";
    private static final String STATS_URL =
        "https://australia-southeast1-logm8-ccb7b.cloudfunctions.net/getAdminDashboardStats";

    public AdminWidgetWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    @NonNull
    @Override
    public Result doWork() {
        Context context = getApplicationContext();
        AdminWidgetState state = AdminWidgetState.load(context);
        try {
            SharedPreferences cap = context.getSharedPreferences(CAPACITOR_PREFS, Context.MODE_PRIVATE);
            String raw = cap.getString(AUTH_KEY, null);
            if (raw == null || raw.isEmpty()) {
                state.error = "Open LogM8 and sign in as the owner";
                state.save(context);
                AdminWidgetProvider.render(context, state);
                return Result.success();
            }
            JSONObject auth = new JSONObject(raw);
            String refreshToken = auth.optString("refreshToken", "");
            if (refreshToken.isEmpty()) {
                throw new IllegalStateException("no refresh token");
            }

            String apiKey = context.getString(R.string.google_api_key);
            String body = "grant_type=refresh_token&refresh_token=" + URLEncoder.encode(refreshToken, "UTF-8");
            JSONObject tokenResponse = new JSONObject(
                post(TOKEN_URL + apiKey, body, "application/x-www-form-urlencoded", null));
            String idToken = tokenResponse.optString("id_token", "");
            if (idToken.isEmpty()) {
                throw new IllegalStateException("token refresh failed");
            }

            JSONObject data = new JSONObject();
            data.put("clientTimeZone", TimeZone.getDefault().getID());
            JSONObject request = new JSONObject().put("data", data);
            String response = post(STATS_URL, request.toString(), "application/json", idToken);
            JSONObject json = new JSONObject(response);
            if (json.has("error")) {
                JSONObject err = json.optJSONObject("error");
                String status = err != null ? err.optString("status", "") : "";
                if ("PERMISSION_DENIED".equalsIgnoreCase(status)) {
                    state.error = "This account is not the LogM8 owner";
                } else {
                    state.error = "Could not load stats";
                }
                state.save(context);
                AdminWidgetProvider.render(context, state);
                return Result.success();
            }
            JSONObject result = json.optJSONObject("result");
            JSONObject totals = result != null ? result.optJSONObject("totals") : null;
            if (totals == null) {
                throw new IllegalStateException("no totals in response");
            }
            long basic = totals.optLong("basic", 0);
            long pro = totals.optLong("pro", 0);
            state.users = totals.optLong("users", 0);
            state.paid = totals.has("paid") ? totals.optLong("paid", 0) : basic + pro;
            state.trial = totals.optLong("trial", 0);
            state.activeToday = totals.optLong("activeToday", 0);
            state.activeMonth = totals.optLong("activeThisMonth", 0);
            state.updatedAtMs = System.currentTimeMillis();
            state.error = null;
            state.save(context);
            AdminWidgetProvider.render(context, state);
            return Result.success();
        } catch (Exception e) {
            state.error = "Update failed - tap to retry";
            state.save(context);
            AdminWidgetProvider.render(context, state);
            return Result.retry();
        }
    }

    private static String post(String url, String body, String contentType, String bearer) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(20000);
        conn.setRequestMethod("POST");
        conn.setDoOutput(true);
        conn.setRequestProperty("Content-Type", contentType);
        conn.setRequestProperty("Accept", "application/json");
        if (bearer != null) {
            conn.setRequestProperty("Authorization", "Bearer " + bearer);
        }
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        try (OutputStream os = conn.getOutputStream()) {
            os.write(bytes);
        }
        int code = conn.getResponseCode();
        InputStream is = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
        StringBuilder sb = new StringBuilder();
        if (is != null) {
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line);
                }
            }
        }
        conn.disconnect();
        String text = sb.toString();
        if (code >= 400 && !text.trim().startsWith("{")) {
            throw new IllegalStateException("HTTP " + code);
        }
        return text;
    }
}
