# Power BI DAX Measures
## NHS Waiting List Analytics Dashboard

All measures connect to the `v_monthly_summary` and `v_national_monthly` views
via DirectQuery or imported mode from MySQL.

---

## Table of Contents

1. [Core KPI Cards](#1-core-kpi-cards)
2. [Waiting List Trend](#2-waiting-list-trend)
3. [Referral vs Treatment Analysis](#3-referral-vs-treatment-analysis)
4. [Long Waiter Metrics](#4-long-waiter-metrics)
5. [Efficiency Ratios](#5-efficiency-ratios)
6. [Regional Benchmarking](#6-regional-benchmarking)
7. [Time Intelligence](#7-time-intelligence)
8. [Dashboard Layout Guide](#8-dashboard-layout-guide)

---

## 1. Core KPI Cards

### Total Patients Waiting
```dax
[Total Waiting] =
SUM ( v_monthly_summary[total_waiting] )
```

### Patients Waiting Over 18 Weeks
```dax
[Waiting Over 18 Weeks] =
SUM ( v_monthly_summary[waiting_over_18wks] )
```

### Patients Waiting Over 52 Weeks (Long Waiters)
```dax
[Long Waiters 52+] =
SUM ( v_monthly_summary[waiting_over_52wks] )
```

### Total Treatments This Period
```dax
[Total Treated] =
SUM ( v_monthly_summary[total_completed] )
```

### New Referrals This Period
```dax
[New Referrals] =
SUM ( v_monthly_summary[new_rtt_periods] )
```

---

## 2. Waiting List Trend

### 18-Week Breach Rate (%)
```dax
[Breach Rate %] =
DIVIDE (
    [Waiting Over 18 Weeks],
    [Total Waiting],
    0
) * 100
```

### Long Waiter Rate (%)
```dax
[Long Waiter Rate %] =
DIVIDE (
    [Long Waiters 52+],
    [Total Waiting],
    0
) * 100
```

### Month-on-Month Change in Waiting List
```dax
[Waiting List MoM Change] =
VAR CurrentTotal = [Total Waiting]
VAR PreviousMonth =
    CALCULATE (
        [Total Waiting],
        DATEADD ( dim_date[full_date], -1, MONTH )
    )
RETURN
    CurrentTotal - PreviousMonth
```

### Year-on-Year Change in Waiting List
```dax
[Waiting List YoY Change] =
VAR CurrentTotal = [Total Waiting]
VAR PriorYear =
    CALCULATE (
        [Total Waiting],
        SAMEPERIODLASTYEAR ( dim_date[full_date] )
    )
RETURN
    CurrentTotal - PriorYear
```

### Waiting List YoY Change %
```dax
[Waiting List YoY %] =
DIVIDE (
    [Waiting List YoY Change],
    CALCULATE (
        [Total Waiting],
        SAMEPERIODLASTYEAR ( dim_date[full_date] )
    ),
    BLANK ()
) * 100
```

---

## 3. Referral vs Treatment Analysis

> **This is the core analytical section.**
> These measures expose the gap between demand (referrals) and supply (treatments).

### Referral-to-Treatment Ratio
```dax
-- > 1.0: more people joining the list than being treated (list growing)
-- < 1.0: more people treated than referred (list shrinking)
-- KEY INSIGHT: if ratio drops AND list shrinks, demand is being suppressed

[Referral to Treatment Ratio] =
DIVIDE (
    [New Referrals],
    [Total Treated],
    BLANK ()
)
```

### Net Flow (Referrals minus Treatments)
```dax
-- Positive = list is growing; Negative = list is shrinking
[Net Flow] =
[New Referrals] - [Total Treated]
```

### Referral Index vs Pre-COVID Baseline
```dax
-- Compares current referral volume to Jan 2020 (pre-COVID baseline = 100)
[Referral Index vs Jan2020] =
VAR Baseline =
    CALCULATE (
        [New Referrals],
        dim_date[full_date] = DATE ( 2020, 1, 1 )
    )
RETURN
    DIVIDE ( [New Referrals], Baseline, BLANK () ) * 100
```

### Treatment Index vs Pre-COVID Baseline
```dax
[Treatment Index vs Jan2020] =
VAR Baseline =
    CALCULATE (
        [Total Treated],
        dim_date[full_date] = DATE ( 2020, 1, 1 )
    )
RETURN
    DIVIDE ( [Total Treated], Baseline, BLANK () ) * 100
```

### Referral Suppression Signal
```dax
-- High positive = referrals growing faster than treatments
-- Large negative = treatments massively outpacing referrals
--   → possible referral gatekeeping or working down the backlog
[Referral Suppression Signal] =
[New Referrals] - [Total Treated]
```

### Throughput Rate (%)
```dax
-- What % of new referrals get treated in the same period?
[Throughput Rate %] =
DIVIDE (
    [Total Treated],
    [New Referrals],
    0
) * 100
```

---

## 4. Long Waiter Metrics

### Long Waiter MoM Change
```dax
[Long Waiter MoM Change] =
VAR Current = [Long Waiters 52+]
VAR Prev =
    CALCULATE (
        [Long Waiters 52+],
        DATEADD ( dim_date[full_date], -1, MONTH )
    )
RETURN
    Current - Prev
```

### Long Waiter Reduction Rate (12-month rolling)
```dax
[Long Waiter 12M Reduction] =
VAR Current = [Long Waiters 52+]
VAR Year1Ago =
    CALCULATE (
        [Long Waiters 52+],
        DATEADD ( dim_date[full_date], -12, MONTH )
    )
RETURN
    DIVIDE ( Current - Year1Ago, Year1Ago, BLANK () ) * 100
```

---

## 5. Efficiency Ratios

### Admitted Pathway Share (%)
```dax
-- What proportion of treatments required a hospital admission?
[Admitted Pathway Share %] =
DIVIDE (
    SUM ( v_monthly_summary[completed_admitted] ),
    [Total Treated],
    0
) * 100
```

### Average Median Wait (Weeks)
```dax
[Avg Median Wait Weeks] =
AVERAGEX (
    SUMMARIZE (
        v_monthly_summary,
        dim_date[full_date],
        dim_trust[trust_name],
        dim_treatment_function[treatment_function_name]
    ),
    CALCULATE ( AVERAGE ( v_monthly_summary[avg_median_wait_weeks] ) )
)
```

### 92nd Percentile Wait (Weeks)
```dax
-- NHS target: 92% of patients treated within 18 weeks
[Avg P92 Wait Weeks] =
AVERAGE ( v_monthly_summary[avg_p92_wait_weeks] )
```

---

## 6. Regional Benchmarking

### Regional Breach Rate (for map visual)
```dax
[Regional Breach Rate %] =
DIVIDE (
    CALCULATE (
        [Waiting Over 18 Weeks],
        ALLEXCEPT ( dim_region, dim_region[region_name] )
    ),
    CALCULATE (
        [Total Waiting],
        ALLEXCEPT ( dim_region, dim_region[region_name] )
    ),
    0
) * 100
```

### Region vs National Breach Rate
```dax
[vs National Breach Rate] =
[Breach Rate %]
    - CALCULATE ( [Breach Rate %], ALL ( dim_region ) )
```

### Regional Referral Index
```dax
-- 1.0 = exactly at national average; > 1.0 = above average referrals
[Regional Referral Index] =
DIVIDE (
    [New Referrals],
    CALCULATE ( [New Referrals], ALL ( dim_region ) )
        / DISTINCTCOUNT ( dim_region[region_name] ),
    BLANK ()
)
```

---

## 7. Time Intelligence

### Rolling 3-Month Average (Waiting List)
```dax
[Waiting List 3M Rolling Avg] =
AVERAGEX (
    DATESINPERIOD (
        dim_date[full_date],
        LASTDATE ( dim_date[full_date] ),
        -3,
        MONTH
    ),
    CALCULATE ( [Total Waiting] )
)
```

### Rolling 12-Month Average (Referrals)
```dax
[Referrals 12M Rolling Avg] =
AVERAGEX (
    DATESINPERIOD (
        dim_date[full_date],
        LASTDATE ( dim_date[full_date] ),
        -12,
        MONTH
    ),
    CALCULATE ( [New Referrals] )
)
```

### Financial Year-to-Date Treated
```dax
[FY-TD Treated] =
CALCULATE (
    [Total Treated],
    DATESYTD ( dim_date[full_date], "31-3" )   -- UK financial year ends 31 March
)
```

---

## 8. Dashboard Layout Guide

### Recommended Pages

**Page 1 — National Overview**
- KPI Cards: Total Waiting | Long Waiters | Breach Rate % | New Referrals | Total Treated
- Line chart: Waiting list + New Referrals + Total Treated (all on one axis, 2015–2025)
- Shaded COVID period (Mar 2020 – Mar 2022)
- Annotation: "Referrals dropped 40% in COVID — list is now bigger than ever"

**Page 2 — The Core Insight: Referrals vs Reality**
- Dual-axis line chart:
  - Left axis: New Referrals (bar)
  - Right axis: Total Waiting (line)
  - Insight: "Referrals suppressed → list appears to stabilise"
- Scatter plot: Referral Index vs Breach Rate by Trust
- Card: Referral-to-Treatment Ratio with trend arrow

**Page 3 — Long Waiter Deep Dive**
- Area chart: 52-week waiters over time by specialty
- Clustered bar: Top 10 specialties by long waiter count
- Waterfall: MoM change (new long waiters vs cleared)
- Card: "Peak 52+ week waiters: [value] in [month]"

**Page 4 — Regional Scorecard**
- Filled map (UK regions): shaded by Breach Rate %
- Matrix: Region × Financial Year → Breach Rate, Throughput Rate, Long Waiter %
- Bar chart: Regional referral index vs national average

**Page 5 — Trust Performance League Table**
- Table: Trust | Region | Breach Rate | Throughput | Median Wait | Referral Signal
- Conditional formatting: red = poor, green = strong
- Slicer: Financial Year, Region, Specialty Group

### Slicer Panel (all pages)
- Financial Year (multi-select)
- NHS Region
- Specialty Group (Surgical / Medical / Mental Health)
- COVID Period (Yes / No)
- Trust (search box)

### Colour Palette
- NHS Blue:      `#005EB8`
- NHS Dark Blue: `#003087`
- NHS Warm Red:  `#DA291C` (breach/risk)
- NHS Green:     `#007F3B` (on-target)
- NHS Mid Grey:  `#768692`
- Background:    `#F0F4F5`
