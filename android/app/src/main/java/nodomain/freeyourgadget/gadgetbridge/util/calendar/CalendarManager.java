/*  Copyright (C) 2022-2024 José Rebelo

    This file is part of Gadgetbridge.

    Gadgetbridge is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Gadgetbridge is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>. */
package nodomain.freeyourgadget.gadgetbridge.util.calendar;

import android.content.ContentUris;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.CalendarContract;
import android.provider.CalendarContract.Instances;
import android.text.format.Time;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.Calendar;
import java.util.GregorianCalendar;
import java.util.List;

/**
 * 读取系统日历事件（移植自 Gadgetbridge，精简掉联系人生日与日历黑名单）
 */
public class CalendarManager {
    private static final Logger LOG = LoggerFactory.getLogger(CalendarManager.class);

    private static final String[] EVENT_INSTANCE_PROJECTION = new String[]{
            Instances._ID,
            Instances.BEGIN,
            Instances.END,
            Instances.DURATION,
            Instances.TITLE,
            Instances.DESCRIPTION,
            Instances.EVENT_LOCATION,
            Instances.ORGANIZER,
            Instances.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            Instances.CALENDAR_COLOR,
            Instances.ALL_DAY,
            Instances.EVENT_ID,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            Instances.CALENDAR_ID,
            Instances.RRULE
    };

    private final Context mContext;
    private final int lookaheadDays;

    public CalendarManager(final Context context, final int lookaheadDays) {
        this.mContext = context;
        this.lookaheadDays = Math.max(1, lookaheadDays);
    }

    public List<CalendarEvent> getCalendarEventList() {
        final List<CalendarEvent> calendarEventList = new ArrayList<>();

        Calendar cal = GregorianCalendar.getInstance();
        long dtStart = cal.getTimeInMillis();
        cal.add(Calendar.DATE, lookaheadDays);
        long dtEnd = cal.getTimeInMillis();

        Uri.Builder eventsUriBuilder = Instances.CONTENT_URI.buildUpon();
        ContentUris.appendId(eventsUriBuilder, dtStart);
        ContentUris.appendId(eventsUriBuilder, dtEnd);
        Uri eventsUri = eventsUriBuilder.build();

        try (Cursor evtCursor = mContext.getContentResolver().query(eventsUri, EVENT_INSTANCE_PROJECTION, null, null, Instances.BEGIN + " ASC")) {
            if (evtCursor == null || evtCursor.getCount() == 0) {
                return calendarEventList;
            }
            while (evtCursor.moveToNext()) {
                long start = evtCursor.getLong(evtCursor.getColumnIndexOrThrow(Instances.BEGIN));
                long end = evtCursor.getLong(evtCursor.getColumnIndexOrThrow(Instances.END));
                if (end == 0) {
                    LOG.info("no end time, will parse duration string");
                    Time time = new Time();
                    time.parse(evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.DURATION)));
                    end = start + time.toMillis(false);
                }

                CalendarEvent calEvent = new CalendarEvent(
                        start,
                        end,
                        evtCursor.getLong(evtCursor.getColumnIndexOrThrow(Instances._ID)),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.TITLE)),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.DESCRIPTION)),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.EVENT_LOCATION)),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.CALENDAR_DISPLAY_NAME)),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_NAME)),
                        evtCursor.getInt(evtCursor.getColumnIndexOrThrow(Instances.CALENDAR_COLOR)),
                        !evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.ALL_DAY)).equals("0"),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.ORGANIZER)),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_TYPE)),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.CALENDAR_ID)),
                        evtCursor.getString(evtCursor.getColumnIndexOrThrow(Instances.RRULE))
                );

                // Query reminders for this event
                final Cursor reminderCursor = mContext.getContentResolver().query(
                        CalendarContract.Reminders.CONTENT_URI,
                        null,
                        CalendarContract.Reminders.EVENT_ID + " = ?",
                        new String[]{String.valueOf(evtCursor.getLong(evtCursor.getColumnIndexOrThrow(Instances.EVENT_ID)))},
                        null
                );

                if (reminderCursor != null && reminderCursor.getCount() > 0) {
                    final List<Long> reminders = new ArrayList<>();
                    while (reminderCursor.moveToNext()) {
                        int minutes = reminderCursor.getInt(reminderCursor.getColumnIndexOrThrow(CalendarContract.Reminders.MINUTES));
                        int method = reminderCursor.getInt(reminderCursor.getColumnIndexOrThrow(CalendarContract.Reminders.METHOD));
                        if (method == 1) //METHOD_ALERT
                            reminders.add(calEvent.getBegin() - minutes * 60 * 1000L);
                    }
                    reminderCursor.close();
                    calEvent.setRemindersAbsoluteTs(reminders);
                }

                calendarEventList.add(calEvent);
            }
            return calendarEventList;
        } catch (final Exception e) {
            LOG.error("could not query calendar, permission denied?", e);
            return calendarEventList;
        }
    }
}
