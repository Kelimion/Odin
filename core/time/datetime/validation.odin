package datetime

// Validation helpers
is_leap_year :: proc(year: int) -> (leap: bool) {
	return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

validate :: proc{validate_date, validate_year_month_day, validate_ordinal}

validate_date :: proc(date: Date) -> (err: Error) {
	return validate(date.year, date.month, date.day)
}

validate_year_month_day :: proc(year, month, day: int) -> (err: Error) {
	if year < MIN_DATE.year || year > MAX_DATE.year {
		return .Invalid_Year
	}
	if month < 1 || month > 12 {
		return .Invalid_Month
	}

	month_days := MONTH_DAYS
	days_this_month := month_days[month]
	if month == 2 && is_leap_year(year) {
		days_this_month = 29
	}

	if day < 1 || day > days_this_month {
		return .Invalid_Day
	}
	return .None
}

validate_ordinal :: proc(ordinal: Ordinal) -> (err: Error) {
	if ordinal < MIN_ORD || ordinal > MAX_ORD {
		return .Invalid_Ordinal
	}
	return
}