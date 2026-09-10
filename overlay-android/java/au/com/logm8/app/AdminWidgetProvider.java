package au.com.logm8.app;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.widget.RemoteViews;

import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.ExistingWorkPolicy;
import androidx.work.OneTimeWorkRequest;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkManager;

import java.util.concurrent.TimeUnit;

/**
 * LogM8 owner widget: shows the admin dashboard totals on the home screen.
 * Data is fetched in the background by {@link AdminWidgetWorker}.
 */
public class AdminWidgetProvider extends AppWidgetProvider {

    public static final String ACTION_REFRESH = "au.com.logm8.app.ADMIN_WIDGET_REFRESH";
    static final String PERIODIC_WORK = "logm8-admin-widget-periodic";
    static final String ONE_TIME_WORK = "logm8-admin-widget-now";

    @Override
    public void onUpdate(Context context, AppWidgetManager appWidgetManager, int[] appWidgetIds) {
        for (int id : appWidgetIds) {
            appWidgetManager.updateAppWidget(id, buildViews(context, AdminWidgetState.load(context), false));
        }
        schedulePeriodic(context);
        refreshNow(context);
    }

    @Override
    public void onEnabled(Context context) {
        schedulePeriodic(context);
        refreshNow(context);
    }

    @Override
    public void onDisabled(Context context) {
        WorkManager.getInstance(context).cancelUniqueWork(PERIODIC_WORK);
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        super.onReceive(context, intent);
        if (intent != null && ACTION_REFRESH.equals(intent.getAction())) {
            AppWidgetManager mgr = AppWidgetManager.getInstance(context);
            int[] ids = mgr.getAppWidgetIds(new ComponentName(context, AdminWidgetProvider.class));
            for (int id : ids) {
                mgr.updateAppWidget(id, buildViews(context, AdminWidgetState.load(context), true));
            }
            refreshNow(context);
        }
    }

    static void schedulePeriodic(Context context) {
        PeriodicWorkRequest request = new PeriodicWorkRequest.Builder(AdminWidgetWorker.class, 15, TimeUnit.MINUTES)
            .build();
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork(PERIODIC_WORK, ExistingPeriodicWorkPolicy.UPDATE, request);
    }

    static void refreshNow(Context context) {
        OneTimeWorkRequest request = new OneTimeWorkRequest.Builder(AdminWidgetWorker.class).build();
        WorkManager.getInstance(context).enqueueUniqueWork(ONE_TIME_WORK, ExistingWorkPolicy.REPLACE, request);
    }

    /** Pushes the given state to every placed widget. */
    static void render(Context context, AdminWidgetState state) {
        AppWidgetManager mgr = AppWidgetManager.getInstance(context);
        int[] ids = mgr.getAppWidgetIds(new ComponentName(context, AdminWidgetProvider.class));
        for (int id : ids) {
            mgr.updateAppWidget(id, buildViews(context, state, false));
        }
    }

    static RemoteViews buildViews(Context context, AdminWidgetState state, boolean refreshing) {
        RemoteViews views = new RemoteViews(context.getPackageName(), R.layout.widget_admin);
        views.setTextViewText(R.id.widget_users, state.fmt(state.users));
        views.setTextViewText(R.id.widget_paid, state.fmt(state.paid));
        views.setTextViewText(R.id.widget_trial, state.fmt(state.trial));
        views.setTextViewText(R.id.widget_active_today, state.fmt(state.activeToday));
        views.setTextViewText(R.id.widget_active_month, state.fmt(state.activeMonth));
        String status;
        if (refreshing) {
            status = "Updating...";
        } else if (state.error != null && !state.error.isEmpty()) {
            status = state.error;
        } else if (state.updatedAtMs > 0) {
            status = "Updated " + state.formatTime(state.updatedAtMs) + " - tap to refresh";
        } else {
            status = "Tap to refresh";
        }
        views.setTextViewText(R.id.widget_status, status);

        // Tap on the numbers: refresh. Tap on the title: open the app.
        Intent refresh = new Intent(context, AdminWidgetProvider.class).setAction(ACTION_REFRESH);
        PendingIntent refreshIntent = PendingIntent.getBroadcast(context, 1, refresh,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        views.setOnClickPendingIntent(R.id.widget_body, refreshIntent);

        Intent open = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (open != null) {
            open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            PendingIntent openIntent = PendingIntent.getActivity(context, 2, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            views.setOnClickPendingIntent(R.id.widget_title, openIntent);
        }
        return views;
    }
}
