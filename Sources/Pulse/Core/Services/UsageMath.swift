import Foundation

/// One point of the usage-rate chart: utilization change in a time bucket.
struct RatePoint: Sendable, Equatable, Identifiable {
    var date: Date
    /// Percentage-point change of the primary gauge during this bucket.
    /// Positive = consuming (red), negative = window rolling off (green).
    var delta: Double

    var id: Date { date }
}

enum UsageMath {
    /// Derives the usage-rate series from raw samples: buckets the window into
    /// `bucket`-sized bins and reports the utilization delta inside each bin
    /// (last sample in bin minus last sample of the previous bin).
    /// Bins without samples are interpolated as zero-change to keep the chart
    /// continuous. Needs at least two samples; returns [] otherwise.
    static func rateSeries(
        samples: [UsageSample],
        window: TimeInterval = 5 * 3600,
        bucket: TimeInterval = 15 * 60,
        now: Date = .now
    ) -> [RatePoint] {
        // Bins align to wall-clock multiples of `bucket` so point identities
        // stay stable across polls — otherwise every refresh shifts every
        // RatePoint.date and the chart tears down and re-animates wholesale.
        let alignedNow = Date(
            timeIntervalSinceReferenceDate:
                (now.timeIntervalSinceReferenceDate / bucket).rounded(.up) * bucket
        )
        let start = alignedNow.addingTimeInterval(-window)
        let relevant = samples.filter { $0.date >= start.addingTimeInterval(-bucket) && $0.primary != nil }
        guard relevant.count >= 2 else { return [] }

        var points: [RatePoint] = []
        var previousValue = relevant.first?.primary
        var index = 0

        var binStart = start
        while binStart < alignedNow {
            let binEnd = binStart.addingTimeInterval(bucket)
            var lastInBin: Double?
            while index < relevant.count, relevant[index].date < binEnd {
                lastInBin = relevant[index].primary ?? lastInBin
                index += 1
            }
            if let value = lastInBin, let previous = previousValue {
                points.append(RatePoint(date: binStart, delta: value - previous))
                previousValue = value
            } else if previousValue != nil {
                points.append(RatePoint(date: binStart, delta: 0))
            }
            binStart = binEnd
        }
        return points
    }

    /// Builds the 7-day bar series from arbitrary per-day totals, filling
    /// missing days with zero so the chart always shows seven labeled bars.
    static func lastSevenDays(
        from dailyTotals: [Date: TokenTotals],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [DailyUsage] {
        lastDays(7, from: dailyTotals, calendar: calendar, now: now)
    }

    /// Last `count` calendar days (gaps zero-filled), ascending.
    static func lastDays(
        _ count: Int,
        from dailyTotals: [Date: TokenTotals],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [DailyUsage] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DailyUsage(date: day, totals: dailyTotals[day] ?? .zero)
        }
    }

    /// Last `count` calendar months (gaps zero-filled), ascending; per-day
    /// totals are folded into their month's first day.
    static func lastMonths(
        _ count: Int,
        from dailyTotals: [Date: TokenTotals],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [DailyUsage] {
        var perMonth: [Date: TokenTotals] = [:]
        for (day, totals) in dailyTotals {
            guard let month = calendar.dateInterval(of: .month, for: day)?.start else { continue }
            perMonth[month, default: .zero].add(totals)
        }
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        return (0..<count).reversed().compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: -offset, to: thisMonth) else { return nil }
            return DailyUsage(date: month, totals: perMonth[month] ?? .zero)
        }
    }

    /// Today's 24 hourly buckets (gaps zero-filled), ascending. `hourlyTotals`
    /// is keyed by start-of-hour dates; entries outside today are ignored.
    static func hoursOfToday(
        from hourlyTotals: [Date: TokenTotals],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [DailyUsage] {
        let dayStart = calendar.startOfDay(for: now)
        return (0..<24).compactMap { hour in
            guard let bucket = calendar.date(byAdding: .hour, value: hour, to: dayStart) else { return nil }
            return DailyUsage(date: bucket, totals: hourlyTotals[bucket] ?? .zero)
        }
    }
}
