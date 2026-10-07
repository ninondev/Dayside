// SPDX-License-Identifier: GPL-3.0-only
//! 「听懂时间」的词表：十六种界面语言说日期、钟点、时区、「在哪儿是几点」的词。
//!
//! 每条是（短语，含义）。短语按自然写法写（带声调、大写都行），装载时经 `text::fold_str` 折叠；多词短语按空格分，
//! 中日韩短语逐字切开（它们本来就不留空格）。共用短语分别记录各语言归属，匹配时保留这些归属；
//! 含义冲突的按上下文在装配阶段判（`morgen` 在德语、荷兰语都是「明天」，前面有 `heute` / `am` 时才是「早上」）。
//! 这是封闭表：不猜词形，不做模糊匹配；认不出的词留给地名那一步（查城市索引，只认精确命中）。

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Period {
    /// 明确的上午（am、午前、오전、上午、de la mañana）。
    Am,
    /// 明确的下午（pm、午後、오후、下午）：1–11 点加 12。
    Pm,
    /// 早上（morning、早上、朝）：只把 12 当 0 点，其余不动。
    Morning,
    /// 中午（中午、昼）：1–5 点加 12，12 点不动。
    Midday,
    /// 下午（afternoon、tarde、Nachmittag）：1–11 点加 12。
    Afternoon,
    /// 晚上（evening、晚上、夜、avond）：1–11 点加 12，12 点是 0 点。
    Evening,
    /// 夜里（night、noche、nacht、夜里）：6–11 点加 12，12 点是 0 点，1–5 点不动（凌晨）。
    Night,
    /// 凌晨（凌晨、未明、새벽、madrugada）：钟点不动。
    SmallHours,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sem {
    Month(u8),
    Weekday(u8),
    /// 星期的缩写（Di / mer / вт / sáb）：很多本身是常用词（西语 mar 是海、德语 so 是这样），只在后面紧跟钟点数字时当星期。
    WeekdayAbbr(u8),
    RelDay(i8),
    RelDayPeriod(i8, Period),
    /// 上一处日期的次日；没有前一处时是明天。
    NextDay,
    NextDayPeriod(Period),
    /// 「今天之内 / 今日中に / 明日中に / 오늘 중으로」：那天、到当天结束（23:59，宿主标明是按默认算的）。
    RelDayEnd(i8),
    /// 星期前面的「下 / next / 来週の / 다음 주」。
    NextWeek,
    ThisWeek,
    LastWeek,
    /// 星期后面的「prochain / próximo / depan / tuần sau」。
    NextAfter,
    Period(Period),
    Noon,
    Midnight,
    /// 数字前面的「at / um / alle / om / pukul / lúc / saat / a las / в」：光秃秃的数字因此可以当钟点。
    ClockBefore,
    /// 紧邻的活动开始词只帮助区分钟点与时长，不并入钟点跨度。
    ClockContextBefore,
    /// 紧邻数字与同语言小时单位的介词，明确这里是钟点。
    ClockHourBefore,
    /// 尚未计算的钟点连接词只保留原有钟点读取，不当成时长。
    ClockContextAfter,
    /// 数字后面的「o'clock / Uhr / uur / 点 / 時 / 시 / giờ / h」。
    ClockAfter,
    /// 分钟数后面的「分 / 분 / phút」。
    MinuteAfter,
    /// 钟点后面的「半 / 반 / rưỡi / e mezza / y media / et demie / e meia」：N:30。
    HalfAfter,
    /// 钟点前面的「halb / half」（德、荷）：halb 4 = 3:30。
    HalfBefore,
    /// 日期里的「日 / 号 / 일」（跟在日数后）。
    DayMark,
    /// 日期里的「月 / 월」（跟在月数后），越南语的「tháng」在月数前。
    MonthMark,
    MonthBefore,
    /// 越南语日期「ngày 3」的「ngày」（日数前）。
    DayBefore,
    YearMark,
    /// 相对时间：「in / dans / en / tra / over / za / через / dalam / em / daqui a」（量在后）。
    RelIn,
    /// 相对时间：「later / from now / 后 / 後 / 후 / sonra / nữa / lagi」（量在前）。
    RelLater,
    /// 「ago / 前 / назад」（量在前、往回）。
    RelAgo,
    /// 「vor / hace / il y a / há」（量在后、往回：vor 20 Minuten = 20 分钟前）。
    RelAgoBefore,
    HourUnit,
    MinuteUnit,
    /// 「half an hour / 半小时 / mezz'ora / pół godziny / полчаса / nửa tiếng / setengah jam」：30 分钟。
    HalfHour,
    /// 「an hour / eine Stunde / une heure / 一个小时」：60 分钟（没有数字的一小时）。
    OneHour,
    /// 「минуту」（через минуту）：没有数字的一分钟。
    OneMinute,
    /// 词表直接给出的固定分钟数。
    FixedMinutes(u16),
    /// 「day / 天 / 日 / 일 / Tag / jour / día / dia / giorno / dag / dzień / день / gün / ngày / hari」：只在「in 2 days」
    /// 「三天后」「3日後」「3일 후」这类相对日期里认（数字 + 天 + 后，或 in + 数字 + 天）。
    DayUnit,
    /// 「个半小时 / 個半小時」：数字后面的「一个半小时」= 数字 + 0.5 小时。
    HourAndHalfUnit,
    /// 两个钟点之间的「to / until / bis / à / al / tot / do / đến / sampai / 到 / 至 / から / 부터」。
    RangeSep,
    /// 时间段起点前的「from / von / de / dalle / van / od / từ / dari」。
    From,
    /// 「between / zwischen / entre / tra / tussen / między / между」。
    Between,
    /// 「and / und / et / y / e / en / i / и / ve / và / dan」。
    And,
    /// 「hora de X / heure de X / ora di X / horário de X / czasu X / giờ X / waktu X / по X」：地名在后。
    ZoneBefore,
    /// 「X time / X Zeit / X tijd / X saati / X时间 / X時間 / X 시간」：地名在前。
    ZoneAfter,
    /// 「in X / à X / en X / in X / w X / ở X / di X / в X / em X」。
    PlaceIn,
    /// 介词与冠词连写的「在」（法 au / aux、葡 no / na / nos / nas、意 nel / nella / negli / nei / nelle、德 im）：后面多半是国家
    /// （au Japon、nos Estados Unidos、negli Stati Uniti、im Iran），只认国家名，认不出当没有线索（au bureau、im Büro），也不投语言票（葡语的 no 也是英语的 no）。
    PlaceInArticle,
    /// 目标：「what time (is it) in X」「X 几点 / 是 X 几点」「X では何時」「X는 몇 시」「сколько в X」。
    TargetAsk,
    /// 目标：「to X / into X / 换成 X / 换算成 X」。
    TargetTo,
    /// 1–12 的数词（钟点用）。
    Number(u8),
    /// 普通名词：有独立的本语言证据时，不按地名读取。
    CommonNoun,
    /// 常用虚词、打招呼、会议用语：永远不当地名。
    Stop,
    /// 「weekday」不单独出现时用的「周 / 星期 / 礼拜」（下周一的「周」由星期短语整条认，这里只防它进地名）。
    Filler,
    // ───── 日期与钟点补充词 ─────
    /// 「for / 持续 / dauert / durée / durante / dura / trwa / в течение / kéo dài / selama」：后面的量是时长。
    DurationBefore,
    /// 「long / lang / 동안 / boyunca / sürecek」：前面的量是时长。
    DurationAfter,
    /// 截止习语，只映射三档钟点：`eod` 18:00、`noon` 12:00、`midnight` 23:59（与显式钟点同现时不算）。
    Idiom(&'static str),
    /// 钟点后的分钟词（一刻 / 三刻 / y cuarto / et quart / e un quarto / e quinze）：值是分钟。「半」仍是 `HalfAfter`。
    AfterMinutes(u8),
    /// 「差一刻」类：menos cuarto / meno un quarto / moins le quart / без четверти（值是分钟；钟点减一小时、分钟 = 60 − 值）。
    BeforeMinutes(u8),
    /// 「差 M 分」的减号词：menos / meno / moins（钟点在前）、без（钟点在后）。
    Minus,
    /// 整点前后的固定偏移词：quarter past / viertel nach / kwart over / kwadrans po / четверть / çeyrek geçe（+15）、
    /// quarter to / viertel vor / kwart voor / za kwadrans / çeyrek kala（−15，钟点是下一个整点）、half past（+30）、
    /// половина（+30，后接序数属格）、dreiviertel（−15）。
    ClockShift(i8),
    /// 「M past H / M nach H / M over H / M po H / M geçe」。
    Past,
    /// 「M to H / M vor H / M voor H / za M H / M kala」：H 是下一个整点。
    ToHour,
    /// 俄语「四分之一 / 一半 + 序数属格」里的序数（четверть третьего = 2:15）：钟点 = 值 − 1。
    HourOrdinal(u8),
    /// 土耳其语带格的钟点数词：宾格（üçü，「M geçe」前）。
    TrAcc(u8),
    /// 土耳其语与格（dörde，「M kala」前）。
    TrDat(u8),
    /// 整个词就是一个钟点（俄语 полтретьего = 2:30 这类）。
    FixedClock(u8, u8),
    /// 「本地时间 / my time / 我这边 / bei mir」：本机时区（与别的时区同现时是目标，单独出现时是来源）。
    LocalZone,
    /// 「unix / epoch / timestamp / 时间戳」：后面的 10 / 13 位数字是 Unix 时间戳。
    UnixCue,
    /// 两次提到之间的连接词（or / which is / i.e. / 即 / つまり / bzw. / soit / o sea / cioè / dus / czyli / т. е. / yani / tức là / yaitu）：
    /// 只用于判「这几处说的是同一时刻」的等价组，不改读法。
    Connector,
    /// 「我在哪儿」的说法（I'm in Berlin、我在上海、東京にいます、서울에 있어요、İstanbul'dayım）：
    /// 地名在 cue 后（日、韩、土在 cue 前），是写这句话的人所在；那处地名不再当任何一处的来源或目标。
    SelfLocation,
    /// 紧邻数字前的价格、版本、比分等词，整段不能当时间。
    NonTimeBefore,
    /// 紧邻数字后的货币、年龄、尺寸等单位，整段不能当时间。
    NonTimeAfter,
    /// Measure/container immediately after a slash fraction; not a general numeric blocker.
    FractionMeasure,
}

#[cfg(test)]
use self::Period::{Afternoon, Am, Evening, Midday, Morning, Night, Pm, SmallHours};
#[cfg(test)]
use self::Sem::*;

/// （短语，含义，语言码）。语言码只用于统计「这句话像哪种语言」，匹配不分语言。
#[cfg(test)]
pub type Entry = (&'static str, Sem, &'static str);

#[cfg(test)]
pub const ENTRIES: &[Entry] = &[
    ("feira", CommonNoun, "pt"),
    // 数量、钟点偏移和活动时长各有明确的引导词。
    ("版本号", NonTimeBefore, "zh"), ("版本號", NonTimeBefore, "zh"),
    ("点意见", NonTimeAfter, "zh"), ("點意見", NonTimeAfter, "zh"),
    ("点建议", NonTimeAfter, "zh"), ("點建議", NonTimeAfter, "zh"),
    ("进行", DurationBefore, "zh"), ("進行", DurationBefore, "zh"),
    ("所要時間", DurationBefore, "ja"),
    ("durasi", DurationBefore, "id"),
    ("com duração de", DurationBefore, "pt"), ("duração de", DurationBefore, "pt"),
    ("grau", NonTimeAfter, "pt"), ("graus", NonTimeAfter, "pt"), ("derajat", NonTimeAfter, "id"),
    ("差", Minus, "zh"), ("过", Past, "zh"), ("過", Past, "zh"),
    ("零", Number(0), "zh"), ("零", Number(0), "ja"),
    ("中午左右", Noon, "zh"), ("e quarto", AfterMinutes(15), "pt"),
    ("次日", NextDay, "zh"), ("隔天", NextDay, "zh"),
    ("昨晚", RelDayPeriod(-1, Evening), "zh"),
    ("sebelum pulang kerja", Idiom("eod"), "id"), ("no fim do expediente", Idiom("eod"), "pt"),
    ("sen", WeekdayAbbr(1), "id"), ("sel", WeekdayAbbr(2), "id"), ("rab", WeekdayAbbr(3), "id"),
    ("kam", WeekdayAbbr(4), "id"), ("jum", WeekdayAbbr(5), "id"), ("sab", WeekdayAbbr(6), "id"), ("min", WeekdayAbbr(7), "id"),
    // 月内的重复日期用常见介词格。
    ("styczniu", Month(1), "pl"), ("lutym", Month(2), "pl"), ("marcu", Month(3), "pl"), ("kwietniu", Month(4), "pl"),
    ("maju", Month(5), "pl"), ("czerwcu", Month(6), "pl"), ("lipcu", Month(7), "pl"), ("sierpniu", Month(8), "pl"),
    ("wrześniu", Month(9), "pl"), ("październiku", Month(10), "pl"), ("listopadzie", Month(11), "pl"), ("grudniu", Month(12), "pl"),
    ("январе", Month(1), "ru"), ("феврале", Month(2), "ru"), ("марте", Month(3), "ru"), ("апреле", Month(4), "ru"),
    ("мае", Month(5), "ru"), ("июне", Month(6), "ru"), ("июле", Month(7), "ru"), ("августе", Month(8), "ru"),
    ("сентябре", Month(9), "ru"), ("октябре", Month(10), "ru"), ("ноябре", Month(11), "ru"), ("декабре", Month(12), "ru"),
    // 起用日与所有格保留整个明确短语。
    ("from today", RelDay(0), "en"), ("as of today", RelDay(0), "en"), ("starting today", RelDay(0), "en"),
    ("today's", RelDay(0), "en"), ("tomorrow's", RelDay(1), "en"), ("tonight's", RelDayPeriod(0, Evening), "en"),
    ("ab heute", RelDay(0), "de"), ("von heute an", RelDay(0), "de"),
    ("desde hoy", RelDay(0), "es"), ("a partir de hoy", RelDay(0), "es"),
    ("à partir d'aujourd'hui", RelDay(0), "fr"), ("dès aujourd'hui", RelDay(0), "fr"),
    ("da oggi", RelDay(0), "it"), ("a partire da oggi", RelDay(0), "it"),
    ("今日から", RelDay(0), "ja"), ("本日から", RelDay(0), "ja"), ("本日より", RelDay(0), "ja"),
    ("오늘부터", RelDay(0), "ko"), ("vanaf vandaag", RelDay(0), "nl"),
    ("od dziś", RelDay(0), "pl"), ("od dzisiaj", RelDay(0), "pl"),
    ("с сегодняшнего дня", RelDay(0), "ru"), ("начиная с сегодня", RelDay(0), "ru"),
    ("bugünden itibaren", RelDay(0), "tr"), ("từ hôm nay", RelDay(0), "vi"),
    ("mulai hari ini", RelDay(0), "id"), ("sejak hari ini", RelDay(0), "id"),
    ("a partir de hoje", RelDay(0), "pt"), ("desde hoje", RelDay(0), "pt"),
    ("即日起", RelDay(0), "zh"), ("自即日起", RelDay(0), "zh"),
    // 周修饰语不按地点读取。
    ("w przyszłym tygodniu", NextWeek, "pl"), ("w zeszłym tygodniu", LastWeek, "pl"), ("w tym tygodniu", ThisWeek, "pl"),
    ("przyszłym tygodniu", Filler, "pl"), ("zeszłym tygodniu", Filler, "pl"), ("tym tygodniu", Filler, "pl"),
    // 日末语法常用的星期属格逐词列明。
    ("montags", Weekday(1), "de"), ("dienstags", Weekday(2), "de"), ("mittwochs", Weekday(3), "de"), ("donnerstags", Weekday(4), "de"),
    ("freitags", Weekday(5), "de"), ("samstags", Weekday(6), "de"), ("sonntags", Weekday(7), "de"),
    ("poniedziałku", Weekday(1), "pl"), ("wtorku", Weekday(2), "pl"), ("środy", Weekday(3), "pl"), ("czwartku", Weekday(4), "pl"),
    ("piątku", Weekday(5), "pl"), ("soboty", Weekday(6), "pl"), ("niedzieli", Weekday(7), "pl"),
    ("понедельника", Weekday(1), "ru"), ("вторника", Weekday(2), "ru"), ("среды", Weekday(3), "ru"), ("четверга", Weekday(4), "ru"),
    ("пятницы", Weekday(5), "ru"), ("субботы", Weekday(6), "ru"), ("воскресенья", Weekday(7), "ru"),
    ("сегодняшнего дня", RelDay(0), "ru"), ("завтрашнего дня", RelDay(1), "ru"),
    // 普通名词只在本语言句段里排除；同名外国地点仍可由明确线索引出。
    ("forno", CommonNoun, "it"), ("piazza", CommonNoun, "it"), ("yoga", CommonNoun, "it"),
    ("foto", CommonNoun, "it"), ("stelle", CommonNoun, "it"), ("luci", CommonNoun, "it"),
    ("페리", CommonNoun, "ko"), ("페리는", CommonNoun, "ko"), ("스탠드업", CommonNoun, "ko"), ("스탠드업은", CommonNoun, "ko"),
    ("로그", CommonNoun, "ko"), ("로그에", CommonNoun, "ko"), ("안내문에는", CommonNoun, "ko"), ("치과", CommonNoun, "ko"), ("약속", CommonNoun, "ko"), ("약속은", CommonNoun, "ko"), ("방송", CommonNoun, "ko"), ("방송은", CommonNoun, "ko"),
    ("tàu", CommonNoun, "vi"), ("bến", CommonNoun, "vi"), ("bếp", CommonNoun, "vi"),
    ("reading", CommonNoun, "en"), ("closing", CommonNoun, "en"), ("tv", CommonNoun, "it"), ("l’aéroport", CommonNoun, "fr"), ("l’événement", CommonNoun, "fr"), ("gare", CommonNoun, "fr"), ("aéroport", CommonNoun, "fr"), ("çay", CommonNoun, "tr"), ("giờ nghỉ", CommonNoun, "vi"), ("チーム", CommonNoun, "ja"), ("シフト", CommonNoun, "ja"), ("スタート", CommonNoun, "ja"), ("バス", CommonNoun, "ja"),
    ("bar", CommonNoun, "de"), ("log", CommonNoun, "pl"), ("лог", CommonNoun, "ru"), ("yayın", CommonNoun, "tr"),
    // The geographic noun in «в районе Сосновки» is not the Mexican city Rayón.
    ("районе", CommonNoun, "ru"),
    ("czynna", Stop, "pl"), ("jest", Stop, "pl"), ("augenarzt", Stop, "de"), ("i", Stop, "it"), ("le", Stop, "it"), ("del", Stop, "it"), ("termin", Stop, "pl"),
    // 共用写法必须保留每一种语言，不能只取表里先出现的那一种。
    ("一", Number(1), "ja"), ("二", Number(2), "ja"), ("三", Number(3), "ja"), ("四", Number(4), "ja"),
    ("五", Number(5), "ja"), ("六", Number(6), "ja"), ("七", Number(7), "ja"), ("八", Number(8), "ja"),
    ("九", Number(9), "ja"), ("十", Number(10), "ja"), ("十一", Number(11), "ja"), ("十二", Number(12), "ja"),
    ("明日", RelDay(1), "ja"), ("今日", RelDay(0), "ja"), ("半", HalfAfter, "ja"),
    ("april", Month(4), "nl"), ("juni", Month(6), "nl"), ("juli", Month(7), "nl"),
    ("september", Month(9), "nl"), ("november", Month(11), "nl"), ("december", Month(12), "nl"),
    ("jan", Month(1), "pt"), ("mar", Month(3), "pt"), ("jun", Month(6), "pt"), ("jul", Month(7), "pt"), ("nov", Month(11), "pt"),
    ("mai", Month(5), "fr"),
    ("april", Month(4), "de"), ("august", Month(8), "de"), ("september", Month(9), "de"), ("november", Month(11), "de"),
    ("sera", Stop, "fr"), ("dan", Stop, "nl"), ("u", PlaceIn, "pl"), ("wizyta", Stop, "pl"),
    ("de", From, "pt"), ("bộ đếm", Stop, "vi"),
    // Only slash fractions use these closed measure/container tables. A bare number
    // or a dotted clock does not gain a new blocker from these entries.
    // en
    ("cup", FractionMeasure, "en"), ("cups", FractionMeasure, "en"), ("teaspoon", FractionMeasure, "en"),
    ("teaspoons", FractionMeasure, "en"), ("tsp", FractionMeasure, "en"), ("tablespoon", FractionMeasure, "en"),
    ("tablespoons", FractionMeasure, "en"), ("tbsp", FractionMeasure, "en"), ("glass", FractionMeasure, "en"),
    ("glasses", FractionMeasure, "en"), ("spoon", FractionMeasure, "en"), ("spoons", FractionMeasure, "en"),
    ("kilogram", FractionMeasure, "en"), ("kilograms", FractionMeasure, "en"), ("gram", FractionMeasure, "en"),
    ("grams", FractionMeasure, "en"), ("milliliter", FractionMeasure, "en"), ("milliliters", FractionMeasure, "en"),
    ("millilitre", FractionMeasure, "en"), ("millilitres", FractionMeasure, "en"), ("liter", FractionMeasure, "en"),
    ("liters", FractionMeasure, "en"), ("litre", FractionMeasure, "en"), ("litres", FractionMeasure, "en"),
    ("kg", FractionMeasure, "en"), ("g", FractionMeasure, "en"), ("ml", FractionMeasure, "en"),
    ("l", FractionMeasure, "en"),
    // de
    ("Tasse", FractionMeasure, "de"), ("Tassen", FractionMeasure, "de"), ("Teelöffel", FractionMeasure, "de"),
    ("Teelöffeln", FractionMeasure, "de"), ("TL", FractionMeasure, "de"), ("Esslöffel", FractionMeasure, "de"),
    ("Esslöffeln", FractionMeasure, "de"), ("EL", FractionMeasure, "de"), ("Glas", FractionMeasure, "de"),
    ("Gläser", FractionMeasure, "de"), ("Glases", FractionMeasure, "de"), ("Löffel", FractionMeasure, "de"),
    ("Löffeln", FractionMeasure, "de"), ("Kilogramm", FractionMeasure, "de"), ("Gramm", FractionMeasure, "de"),
    ("Milliliter", FractionMeasure, "de"), ("Liter", FractionMeasure, "de"), ("kg", FractionMeasure, "de"),
    ("g", FractionMeasure, "de"), ("ml", FractionMeasure, "de"), ("l", FractionMeasure, "de"),
    // es
    ("taza", FractionMeasure, "es"), ("tazas", FractionMeasure, "es"), ("cucharadita", FractionMeasure, "es"),
    ("cucharaditas", FractionMeasure, "es"), ("cucharada", FractionMeasure, "es"), ("cucharadas", FractionMeasure, "es"),
    ("vaso", FractionMeasure, "es"), ("vasos", FractionMeasure, "es"), ("cuchara", FractionMeasure, "es"),
    ("cucharas", FractionMeasure, "es"), ("kilogramo", FractionMeasure, "es"), ("kilogramos", FractionMeasure, "es"),
    ("kilo", FractionMeasure, "es"), ("kilos", FractionMeasure, "es"), ("gramo", FractionMeasure, "es"),
    ("gramos", FractionMeasure, "es"), ("mililitro", FractionMeasure, "es"), ("mililitros", FractionMeasure, "es"),
    ("litro", FractionMeasure, "es"), ("litros", FractionMeasure, "es"), ("kg", FractionMeasure, "es"),
    ("g", FractionMeasure, "es"), ("ml", FractionMeasure, "es"), ("l", FractionMeasure, "es"),
    // fr
    ("tasse", FractionMeasure, "fr"), ("tasses", FractionMeasure, "fr"), ("cuillère à café", FractionMeasure, "fr"),
    ("cuillères à café", FractionMeasure, "fr"), ("cuiller à café", FractionMeasure, "fr"), ("cuillers à café", FractionMeasure, "fr"),
    ("cuillère à soupe", FractionMeasure, "fr"), ("cuillères à soupe", FractionMeasure, "fr"), ("cuiller à soupe", FractionMeasure, "fr"),
    ("cuillers à soupe", FractionMeasure, "fr"), ("verre", FractionMeasure, "fr"), ("verres", FractionMeasure, "fr"),
    ("cuillère", FractionMeasure, "fr"), ("cuillères", FractionMeasure, "fr"), ("cuiller", FractionMeasure, "fr"),
    ("cuillers", FractionMeasure, "fr"), ("kilogramme", FractionMeasure, "fr"), ("kilogrammes", FractionMeasure, "fr"),
    ("gramme", FractionMeasure, "fr"), ("grammes", FractionMeasure, "fr"), ("millilitre", FractionMeasure, "fr"),
    ("millilitres", FractionMeasure, "fr"), ("litre", FractionMeasure, "fr"), ("litres", FractionMeasure, "fr"),
    ("kg", FractionMeasure, "fr"), ("g", FractionMeasure, "fr"), ("ml", FractionMeasure, "fr"),
    ("l", FractionMeasure, "fr"),
    // it
    ("tazza", FractionMeasure, "it"), ("tazze", FractionMeasure, "it"), ("cucchiaino", FractionMeasure, "it"),
    ("cucchiaini", FractionMeasure, "it"), ("cucchiaio", FractionMeasure, "it"), ("cucchiai", FractionMeasure, "it"),
    ("cucchiaio da tavola", FractionMeasure, "it"), ("cucchiai da tavola", FractionMeasure, "it"), ("bicchiere", FractionMeasure, "it"),
    ("bicchieri", FractionMeasure, "it"), ("chilogrammo", FractionMeasure, "it"), ("chilogrammi", FractionMeasure, "it"),
    ("chilo", FractionMeasure, "it"), ("chili", FractionMeasure, "it"), ("grammo", FractionMeasure, "it"),
    ("grammi", FractionMeasure, "it"), ("millilitro", FractionMeasure, "it"), ("millilitri", FractionMeasure, "it"),
    ("litro", FractionMeasure, "it"), ("litri", FractionMeasure, "it"), ("kg", FractionMeasure, "it"),
    ("g", FractionMeasure, "it"), ("ml", FractionMeasure, "it"), ("l", FractionMeasure, "it"),
    // ja
    ("カップ", FractionMeasure, "ja"), ("小さじ", FractionMeasure, "ja"), ("茶さじ", FractionMeasure, "ja"),
    ("ティースプーン", FractionMeasure, "ja"), ("大さじ", FractionMeasure, "ja"), ("テーブルスプーン", FractionMeasure, "ja"),
    ("グラス", FractionMeasure, "ja"), ("スプーン", FractionMeasure, "ja"), ("キログラム", FractionMeasure, "ja"),
    ("グラム", FractionMeasure, "ja"), ("ミリリットル", FractionMeasure, "ja"), ("リットル", FractionMeasure, "ja"),
    ("kg", FractionMeasure, "ja"), ("g", FractionMeasure, "ja"), ("ml", FractionMeasure, "ja"),
    ("l", FractionMeasure, "ja"),
    // ko
    ("컵", FractionMeasure, "ko"), ("작은술", FractionMeasure, "ko"), ("티스푼", FractionMeasure, "ko"),
    ("큰술", FractionMeasure, "ko"), ("테이블스푼", FractionMeasure, "ko"), ("잔", FractionMeasure, "ko"),
    ("숟가락", FractionMeasure, "ko"), ("스푼", FractionMeasure, "ko"), ("킬로그램", FractionMeasure, "ko"),
    ("그램", FractionMeasure, "ko"), ("밀리리터", FractionMeasure, "ko"), ("리터", FractionMeasure, "ko"),
    ("kg", FractionMeasure, "ko"), ("g", FractionMeasure, "ko"), ("ml", FractionMeasure, "ko"),
    ("l", FractionMeasure, "ko"),
    // nl
    ("kop", FractionMeasure, "nl"), ("koppen", FractionMeasure, "nl"), ("kopje", FractionMeasure, "nl"),
    ("kopjes", FractionMeasure, "nl"), ("theelepel", FractionMeasure, "nl"), ("theelepels", FractionMeasure, "nl"),
    ("eetlepel", FractionMeasure, "nl"), ("eetlepels", FractionMeasure, "nl"), ("glas", FractionMeasure, "nl"),
    ("glazen", FractionMeasure, "nl"), ("lepel", FractionMeasure, "nl"), ("lepels", FractionMeasure, "nl"),
    ("kilogram", FractionMeasure, "nl"), ("gram", FractionMeasure, "nl"), ("milliliter", FractionMeasure, "nl"),
    ("liter", FractionMeasure, "nl"), ("kg", FractionMeasure, "nl"), ("g", FractionMeasure, "nl"),
    ("ml", FractionMeasure, "nl"), ("l", FractionMeasure, "nl"),
    // pl
    ("szklanka", FractionMeasure, "pl"), ("szklanki", FractionMeasure, "pl"), ("szklanek", FractionMeasure, "pl"),
    ("filiżanka", FractionMeasure, "pl"), ("filiżanki", FractionMeasure, "pl"), ("filiżanek", FractionMeasure, "pl"),
    ("łyżeczka", FractionMeasure, "pl"), ("łyżeczki", FractionMeasure, "pl"), ("łyżeczek", FractionMeasure, "pl"),
    ("łyżeczka do herbaty", FractionMeasure, "pl"), ("łyżeczki do herbaty", FractionMeasure, "pl"), ("łyżka", FractionMeasure, "pl"),
    ("łyżki", FractionMeasure, "pl"), ("łyżek", FractionMeasure, "pl"), ("łyżka stołowa", FractionMeasure, "pl"),
    ("łyżki stołowej", FractionMeasure, "pl"), ("łyżki stołowe", FractionMeasure, "pl"), ("łyżek stołowych", FractionMeasure, "pl"),
    ("kilogram", FractionMeasure, "pl"), ("kilograma", FractionMeasure, "pl"), ("kilogramy", FractionMeasure, "pl"),
    ("kilogramów", FractionMeasure, "pl"), ("gram", FractionMeasure, "pl"), ("grama", FractionMeasure, "pl"),
    ("gramy", FractionMeasure, "pl"), ("gramów", FractionMeasure, "pl"), ("mililitr", FractionMeasure, "pl"),
    ("mililitra", FractionMeasure, "pl"), ("mililitry", FractionMeasure, "pl"), ("mililitrów", FractionMeasure, "pl"),
    ("litr", FractionMeasure, "pl"), ("litra", FractionMeasure, "pl"), ("litry", FractionMeasure, "pl"),
    ("litrów", FractionMeasure, "pl"), ("kg", FractionMeasure, "pl"), ("g", FractionMeasure, "pl"),
    ("ml", FractionMeasure, "pl"), ("l", FractionMeasure, "pl"),
    // ru
    ("чашка", FractionMeasure, "ru"), ("чашки", FractionMeasure, "ru"), ("чашек", FractionMeasure, "ru"),
    ("чайная ложка", FractionMeasure, "ru"), ("чайной ложки", FractionMeasure, "ru"), ("чайные ложки", FractionMeasure, "ru"),
    ("чайных ложек", FractionMeasure, "ru"), ("столовая ложка", FractionMeasure, "ru"), ("столовой ложки", FractionMeasure, "ru"),
    ("столовые ложки", FractionMeasure, "ru"), ("столовых ложек", FractionMeasure, "ru"), ("стакан", FractionMeasure, "ru"),
    ("стакана", FractionMeasure, "ru"), ("стаканы", FractionMeasure, "ru"), ("стаканов", FractionMeasure, "ru"),
    ("ложка", FractionMeasure, "ru"), ("ложки", FractionMeasure, "ru"), ("ложек", FractionMeasure, "ru"),
    ("килограмм", FractionMeasure, "ru"), ("килограмма", FractionMeasure, "ru"), ("килограммы", FractionMeasure, "ru"),
    ("килограммов", FractionMeasure, "ru"), ("кг", FractionMeasure, "ru"), ("грамм", FractionMeasure, "ru"),
    ("грамма", FractionMeasure, "ru"), ("граммы", FractionMeasure, "ru"), ("граммов", FractionMeasure, "ru"),
    ("г", FractionMeasure, "ru"), ("миллилитр", FractionMeasure, "ru"), ("миллилитра", FractionMeasure, "ru"),
    ("миллилитры", FractionMeasure, "ru"), ("миллилитров", FractionMeasure, "ru"), ("мл", FractionMeasure, "ru"),
    ("литр", FractionMeasure, "ru"), ("литра", FractionMeasure, "ru"), ("литры", FractionMeasure, "ru"),
    ("литров", FractionMeasure, "ru"), ("л", FractionMeasure, "ru"), ("kg", FractionMeasure, "ru"),
    ("g", FractionMeasure, "ru"), ("ml", FractionMeasure, "ru"), ("l", FractionMeasure, "ru"),
    // tr
    ("fincan", FractionMeasure, "tr"), ("fincanı", FractionMeasure, "tr"), ("fincanlar", FractionMeasure, "tr"),
    ("çay kaşığı", FractionMeasure, "tr"), ("çay kaşıkları", FractionMeasure, "tr"), ("tatlı kaşığı", FractionMeasure, "tr"),
    ("yemek kaşığı", FractionMeasure, "tr"), ("yemek kaşıkları", FractionMeasure, "tr"), ("bardak", FractionMeasure, "tr"),
    ("bardağı", FractionMeasure, "tr"), ("bardaklar", FractionMeasure, "tr"), ("su bardağı", FractionMeasure, "tr"),
    ("kaşık", FractionMeasure, "tr"), ("kaşığı", FractionMeasure, "tr"), ("kaşıklar", FractionMeasure, "tr"),
    ("kilogram", FractionMeasure, "tr"), ("kilo", FractionMeasure, "tr"), ("gram", FractionMeasure, "tr"),
    ("mililitre", FractionMeasure, "tr"), ("litre", FractionMeasure, "tr"), ("kg", FractionMeasure, "tr"),
    ("g", FractionMeasure, "tr"), ("ml", FractionMeasure, "tr"), ("l", FractionMeasure, "tr"),
    // vi
    ("cốc", FractionMeasure, "vi"), ("tách", FractionMeasure, "vi"), ("chén", FractionMeasure, "vi"),
    ("thìa cà phê", FractionMeasure, "vi"), ("muỗng cà phê", FractionMeasure, "vi"), ("thìa canh", FractionMeasure, "vi"),
    ("muỗng canh", FractionMeasure, "vi"), ("ly", FractionMeasure, "vi"), ("thìa", FractionMeasure, "vi"),
    ("muỗng", FractionMeasure, "vi"), ("kilôgam", FractionMeasure, "vi"), ("kilogam", FractionMeasure, "vi"),
    ("ki lô gam", FractionMeasure, "vi"), ("gam", FractionMeasure, "vi"), ("gram", FractionMeasure, "vi"),
    ("mililít", FractionMeasure, "vi"), ("mililit", FractionMeasure, "vi"), ("lít", FractionMeasure, "vi"),
    ("lit", FractionMeasure, "vi"), ("kg", FractionMeasure, "vi"), ("g", FractionMeasure, "vi"),
    ("ml", FractionMeasure, "vi"), ("l", FractionMeasure, "vi"),
    // id
    ("cangkir", FractionMeasure, "id"), ("sendok teh", FractionMeasure, "id"), ("sendok makan", FractionMeasure, "id"),
    ("gelas", FractionMeasure, "id"), ("sendok", FractionMeasure, "id"), ("kilogram", FractionMeasure, "id"),
    ("gram", FractionMeasure, "id"), ("mililiter", FractionMeasure, "id"), ("liter", FractionMeasure, "id"),
    ("kg", FractionMeasure, "id"), ("g", FractionMeasure, "id"), ("ml", FractionMeasure, "id"),
    ("l", FractionMeasure, "id"),
    // pt
    ("xícara", FractionMeasure, "pt"), ("xícaras", FractionMeasure, "pt"), ("chávena", FractionMeasure, "pt"),
    ("chávenas", FractionMeasure, "pt"), ("colher de chá", FractionMeasure, "pt"), ("colheres de chá", FractionMeasure, "pt"),
    ("colher de sopa", FractionMeasure, "pt"), ("colheres de sopa", FractionMeasure, "pt"), ("copo", FractionMeasure, "pt"),
    ("copos", FractionMeasure, "pt"), ("colher", FractionMeasure, "pt"), ("colheres", FractionMeasure, "pt"),
    ("quilograma", FractionMeasure, "pt"), ("quilogramas", FractionMeasure, "pt"), ("quilo", FractionMeasure, "pt"),
    ("quilos", FractionMeasure, "pt"), ("grama", FractionMeasure, "pt"), ("gramas", FractionMeasure, "pt"),
    ("mililitro", FractionMeasure, "pt"), ("mililitros", FractionMeasure, "pt"), ("litro", FractionMeasure, "pt"),
    ("litros", FractionMeasure, "pt"), ("de xícara", FractionMeasure, "pt"), ("de xícaras", FractionMeasure, "pt"),
    ("de chávena", FractionMeasure, "pt"), ("de chávenas", FractionMeasure, "pt"), ("kg", FractionMeasure, "pt"),
    ("g", FractionMeasure, "pt"), ("ml", FractionMeasure, "pt"), ("l", FractionMeasure, "pt"),
    // zh-Hans / zh-Hant (shared zh language tag)
    ("杯", FractionMeasure, "zh"), ("茶匙", FractionMeasure, "zh"), ("小匙", FractionMeasure, "zh"),
    ("小勺", FractionMeasure, "zh"), ("大匙", FractionMeasure, "zh"), ("大勺", FractionMeasure, "zh"),
    ("汤匙", FractionMeasure, "zh"), ("湯匙", FractionMeasure, "zh"), ("玻璃杯", FractionMeasure, "zh"),
    ("匙", FractionMeasure, "zh"), ("勺", FractionMeasure, "zh"), ("勺子", FractionMeasure, "zh"),
    ("公斤", FractionMeasure, "zh"), ("千克", FractionMeasure, "zh"), ("克", FractionMeasure, "zh"),
    ("公克", FractionMeasure, "zh"), ("毫升", FractionMeasure, "zh"), ("毫公升", FractionMeasure, "zh"),
    ("升", FractionMeasure, "zh"), ("公升", FractionMeasure, "zh"), ("kg", FractionMeasure, "zh"),
    ("g", FractionMeasure, "zh"), ("ml", FractionMeasure, "zh"), ("l", FractionMeasure, "zh"),
    // 数字段两侧的封闭分类词表；复合短语也必须紧邻数字。
    ("cup", NonTimeAfter, "en"), ("cups", NonTimeAfter, "en"),
    ("taza", NonTimeAfter, "es"), ("tazas", NonTimeAfter, "es"),
    ("litre", NonTimeAfter, "fr"), ("litres", NonTimeAfter, "fr"),
    ("tazza", NonTimeAfter, "it"), ("tazze", NonTimeAfter, "it"),
    ("kopje", NonTimeAfter, "nl"), ("kopjes", NonTimeAfter, "nl"),
    ("szklanki", NonTimeAfter, "pl"),
    ("чайной ложки", NonTimeAfter, "ru"), ("стакана", NonTimeAfter, "ru"),
    ("su bardağı", NonTimeAfter, "tr"), ("thìa", NonTimeAfter, "vi"), ("カップ", NonTimeAfter, "ja"),
    ("costs", NonTimeBefore, "en"), ("cost", NonTimeBefore, "en"), ("costing", NonTimeBefore, "en"), ("version", NonTimeBefore, "en"), ("versions", NonTimeBefore, "en"), ("release", NonTimeBefore, "en"), ("score", NonTimeBefore, "en"), ("result", NonTimeBefore, "en"), ("code", NonTimeBefore, "en"),
    ("dollar", NonTimeAfter, "en"), ("dollars", NonTimeAfter, "en"), ("USD", NonTimeAfter, "en"), ("pound", NonTimeAfter, "en"), ("pounds", NonTimeAfter, "en"), ("GBP", NonTimeAfter, "en"), ("euro", NonTimeAfter, "en"), ("euros", NonTimeAfter, "en"), ("EUR", NonTimeAfter, "en"), ("cent", NonTimeAfter, "en"), ("cents", NonTimeAfter, "en"), ("percent", NonTimeAfter, "en"), ("years", NonTimeAfter, "en"), ("year", NonTimeAfter, "en"), ("years old", NonTimeAfter, "en"), ("kg", NonTimeAfter, "en"), ("cm", NonTimeAfter, "en"),
    ("kostet", NonTimeBefore, "de"), ("kostet hier", NonTimeBefore, "de"), ("kosten", NonTimeBefore, "de"), ("version", NonTimeBefore, "de"), ("gewannen mit", NonTimeBefore, "de"), ("stand", NonTimeBefore, "de"), ("ergebnis", NonTimeBefore, "de"), ("spielstand", NonTimeBefore, "de"),
    ("euro", NonTimeAfter, "de"), ("euros", NonTimeAfter, "de"), ("EUR", NonTimeAfter, "de"), ("prozent", NonTimeAfter, "de"), ("jahre", NonTimeAfter, "de"), ("jahren", NonTimeAfter, "de"), ("kg", NonTimeAfter, "de"), ("cm", NonTimeAfter, "de"), ("tasse", NonTimeAfter, "de"), ("tassen", NonTimeAfter, "de"),
    ("cuesta", NonTimeBefore, "es"), ("cuestan", NonTimeBefore, "es"), ("versión", NonTimeBefore, "es"), ("versiones", NonTimeBefore, "es"), ("resultado", NonTimeBefore, "es"), ("marcador", NonTimeBefore, "es"),
    ("euro", NonTimeAfter, "es"), ("euros", NonTimeAfter, "es"), ("pesos", NonTimeAfter, "es"), ("por ciento", NonTimeAfter, "es"), ("años", NonTimeAfter, "es"), ("grados", NonTimeAfter, "es"), ("kg", NonTimeAfter, "es"), ("cm", NonTimeAfter, "es"),
    ("coûte", NonTimeBefore, "fr"), ("coûtent", NonTimeBefore, "fr"), ("version", NonTimeBefore, "fr"), ("résultat", NonTimeBefore, "fr"), ("score", NonTimeBefore, "fr"),
    ("euro", NonTimeAfter, "fr"), ("euros", NonTimeAfter, "fr"), ("ans", NonTimeAfter, "fr"), ("pour cent", NonTimeAfter, "fr"), ("degrés", NonTimeAfter, "fr"), ("kg", NonTimeAfter, "fr"), ("cm", NonTimeAfter, "fr"),
    ("costa", NonTimeBefore, "it"), ("versione", NonTimeBefore, "it"), ("risultato", NonTimeBefore, "it"),
    ("euro", NonTimeAfter, "it"), ("euros", NonTimeAfter, "it"), ("anni", NonTimeAfter, "it"), ("percento", NonTimeAfter, "it"), ("gradi", NonTimeAfter, "it"), ("kg", NonTimeAfter, "it"), ("cm", NonTimeAfter, "it"),
    ("custa", NonTimeBefore, "pt"), ("custam", NonTimeBefore, "pt"), ("versão", NonTimeBefore, "pt"), ("resultado", NonTimeBefore, "pt"),
    ("reais", NonTimeAfter, "pt"), ("euros", NonTimeAfter, "pt"), ("anos", NonTimeAfter, "pt"), ("por cento", NonTimeAfter, "pt"), ("kg", NonTimeAfter, "pt"), ("cm", NonTimeAfter, "pt"),
    ("kost", NonTimeBefore, "nl"), ("versie", NonTimeBefore, "nl"), ("uitslag", NonTimeBefore, "nl"),
    ("euro", NonTimeAfter, "nl"), ("euros", NonTimeAfter, "nl"), ("jaar", NonTimeAfter, "nl"), ("procent", NonTimeAfter, "nl"), ("kg", NonTimeAfter, "nl"), ("cm", NonTimeAfter, "nl"),
    ("kosztuje", NonTimeBefore, "pl"), ("kosztują", NonTimeBefore, "pl"), ("wersja", NonTimeBefore, "pl"), ("skończyło się", NonTimeBefore, "pl"), ("wynik", NonTimeBefore, "pl"),
    ("zł", NonTimeAfter, "pl"), ("PLN", NonTimeAfter, "pl"), ("lat", NonTimeAfter, "pl"), ("lata", NonTimeAfter, "pl"), ("procent", NonTimeAfter, "pl"), ("kg", NonTimeAfter, "pl"), ("cm", NonTimeAfter, "pl"),
    ("версия", NonTimeBefore, "ru"), ("версии", NonTimeBefore, "ru"), ("версию", NonTimeBefore, "ru"), ("счёт", NonTimeBefore, "ru"), ("результат", NonTimeBefore, "ru"),
    ("руб", NonTimeAfter, "ru"), ("рублей", NonTimeAfter, "ru"), ("лет", NonTimeAfter, "ru"), ("года", NonTimeAfter, "ru"), ("процентов", NonTimeAfter, "ru"), ("кг", NonTimeAfter, "ru"), ("см", NonTimeAfter, "ru"),
    ("sürüm", NonTimeBefore, "tr"), ("sürümü", NonTimeBefore, "tr"), ("durum", NonTimeBefore, "tr"), ("skor", NonTimeBefore, "tr"),
    ("lira", NonTimeAfter, "tr"), ("TL", NonTimeAfter, "tr"), ("yaş", NonTimeAfter, "tr"), ("yüzde", NonTimeAfter, "tr"), ("kg", NonTimeAfter, "tr"), ("cm", NonTimeAfter, "tr"),
    ("phiên bản", NonTimeBefore, "vi"), ("giá", NonTimeBefore, "vi"), ("tỷ số", NonTimeBefore, "vi"),
    ("đồng", NonTimeAfter, "vi"), ("tuổi", NonTimeAfter, "vi"), ("phần trăm", NonTimeAfter, "vi"), ("kg", NonTimeAfter, "vi"), ("cm", NonTimeAfter, "vi"),
    ("バージョン", NonTimeBefore, "ja"), ("価格", NonTimeBefore, "ja"), ("得点", NonTimeBefore, "ja"),
    ("円", NonTimeAfter, "ja"), ("ドル", NonTimeAfter, "ja"), ("歳", NonTimeAfter, "ja"), ("kg", NonTimeAfter, "ja"), ("cm", NonTimeAfter, "ja"),
    ("버전", NonTimeBefore, "ko"), ("펌웨어", NonTimeBefore, "ko"), ("가격", NonTimeBefore, "ko"), ("점수", NonTimeBefore, "ko"),
    ("달러", NonTimeAfter, "ko"), ("달러였어요", NonTimeAfter, "ko"), ("원", NonTimeAfter, "ko"), ("세", NonTimeAfter, "ko"), ("kg", NonTimeAfter, "ko"), ("cm", NonTimeAfter, "ko"),
    ("版本", NonTimeBefore, "zh"), ("价格", NonTimeBefore, "zh"), ("價格", NonTimeBefore, "zh"), ("比分", NonTimeBefore, "zh"),
    ("元", NonTimeAfter, "zh"), ("美元", NonTimeAfter, "zh"), ("欧元", NonTimeAfter, "zh"), ("歐元", NonTimeAfter, "zh"), ("岁", NonTimeAfter, "zh"), ("歲", NonTimeAfter, "zh"), ("公斤", NonTimeAfter, "zh"), ("厘米", NonTimeAfter, "zh"),
    ("versi", NonTimeBefore, "id"), ("harga", NonTimeBefore, "id"), ("skor", NonTimeBefore, "id"),
    ("rupiah", NonTimeAfter, "id"), ("tahun", NonTimeAfter, "id"), ("persen", NonTimeAfter, "id"), ("kg", NonTimeAfter, "id"), ("cm", NonTimeAfter, "id"),
    ("$", NonTimeBefore, ""), ("€", NonTimeBefore, ""), ("£", NonTimeBefore, ""), ("¥", NonTimeBefore, ""), ("₩", NonTimeBefore, ""),
    ("$", NonTimeAfter, ""), ("€", NonTimeAfter, ""), ("£", NonTimeAfter, ""), ("¥", NonTimeAfter, ""), ("₩", NonTimeAfter, ""), ("%", NonTimeAfter, ""), ("°", NonTimeAfter, ""),
    ("演示", DurationBefore, "zh"), ("sesi tanya jawab", DurationBefore, "id"), ("di ritardo", DurationAfter, "it"),
    // ─────────────── English ───────────────
    ("january", Month(1), "en"), ("jan", Month(1), "en"), ("february", Month(2), "en"), ("feb", Month(2), "en"),
    ("march", Month(3), "en"), ("mar", Month(3), "en"), ("april", Month(4), "en"), ("apr", Month(4), "en"), ("may", Month(5), "en"),
    ("june", Month(6), "en"), ("jun", Month(6), "en"), ("july", Month(7), "en"), ("jul", Month(7), "en"), ("august", Month(8), "en"),
    ("aug", Month(8), "en"), ("september", Month(9), "en"), ("sep", Month(9), "en"), ("sept", Month(9), "en"), ("october", Month(10), "en"),
    ("oct", Month(10), "en"), ("november", Month(11), "en"), ("nov", Month(11), "en"), ("december", Month(12), "en"), ("dec", Month(12), "en"),
    ("monday", Weekday(1), "en"), ("mon", WeekdayAbbr(1), "en"), ("tuesday", Weekday(2), "en"), ("tue", WeekdayAbbr(2), "en"), ("tues", WeekdayAbbr(2), "en"),
    ("wednesday", Weekday(3), "en"), ("wed", WeekdayAbbr(3), "en"), ("thursday", Weekday(4), "en"), ("thu", WeekdayAbbr(4), "en"), ("thur", WeekdayAbbr(4), "en"),
    ("thurs", WeekdayAbbr(4), "en"), ("friday", Weekday(5), "en"), ("fri", WeekdayAbbr(5), "en"), ("saturday", Weekday(6), "en"), ("sat", WeekdayAbbr(6), "en"),
    ("sunday", Weekday(7), "en"), ("sun", WeekdayAbbr(7), "en"),
    ("today", RelDay(0), "en"), ("tomorrow", RelDay(1), "en"), ("tmrw", RelDay(1), "en"), ("tmr", RelDay(1), "en"), ("tomorow", RelDay(1), "en"),
    ("yesterday", RelDay(-1), "en"), ("day after tomorrow", RelDay(2), "en"), ("the day after tomorrow", RelDay(2), "en"),
    ("day before yesterday", RelDay(-2), "en"), ("tonight", RelDayPeriod(0, Evening), "en"), ("this morning", RelDayPeriod(0, Morning), "en"),
    ("this afternoon", RelDayPeriod(0, Afternoon), "en"), ("this evening", RelDayPeriod(0, Evening), "en"),
    ("tomorrow morning", RelDayPeriod(1, Morning), "en"), ("tomorrow afternoon", RelDayPeriod(1, Afternoon), "en"),
    ("tomorrow evening", RelDayPeriod(1, Evening), "en"), ("tomorrow night", RelDayPeriod(1, Evening), "en"),
    ("next", NextWeek, "en"), ("this", ThisWeek, "en"), ("this coming", NextWeek, "en"), ("last", LastWeek, "en"),
    ("am", Period(Am), "en"), ("a.m", Period(Am), "en"), ("a.m.", Period(Am), "en"), ("pm", Period(Pm), "en"), ("p.m", Period(Pm), "en"), ("p.m.", Period(Pm), "en"),
    ("in the morning", Period(Morning), "en"), ("morning", Period(Morning), "en"), ("in the afternoon", Period(Afternoon), "en"), ("afternoon", Period(Afternoon), "en"),
    ("in the evening", Period(Evening), "en"), ("evening", Period(Evening), "en"), ("at night", Period(Night), "en"), ("night", Period(Night), "en"),
    ("noon", Noon, "en"), ("midday", Noon, "en"), ("midnight", Midnight, "en"),
    ("at", ClockBefore, "en"), ("@", ClockBefore, "en"), ("around", ClockBefore, "en"), ("by", ClockBefore, "en"),
    ("o'clock", ClockAfter, "en"), ("oclock", ClockAfter, "en"), ("hrs", ClockAfter, "en"),
    ("in", RelIn, "en"), ("from now", RelLater, "en"), ("later", RelLater, "en"), ("ago", RelAgo, "en"),
    ("hours", HourUnit, "en"), ("hour", HourUnit, "en"), ("hrs", HourUnit, "en"), ("hr", HourUnit, "en"), ("h", HourUnit, "en"),
    ("minutes", MinuteUnit, "en"), ("minute", MinuteUnit, "en"), ("mins", MinuteUnit, "en"), ("min", MinuteUnit, "en"),
    ("half an hour", HalfHour, "en"), ("an hour", OneHour, "en"), ("one hour", OneHour, "en"),
    ("to", RangeSep, "en"), ("until", RangeSep, "en"), ("till", RangeSep, "en"), ("through", RangeSep, "en"), ("-", RangeSep, "en"),
    ("from", From, "en"), ("between", Between, "en"), ("and", And, "en"),
    ("time", ZoneAfter, "en"), ("in", PlaceIn, "en"),
    ("what time is it in", TargetAsk, "en"), ("what time in", TargetAsk, "en"), ("what time will it be in", TargetAsk, "en"),
    ("what's that in", TargetAsk, "en"), ("whats that in", TargetAsk, "en"), ("what is that in", TargetAsk, "en"), ("in", TargetTo, "en"),
    ("to", TargetTo, "en"), ("into", TargetTo, "en"), ("for", TargetTo, "en"),
    ("one", Number(1), "en"), ("two", Number(2), "en"), ("three", Number(3), "en"), ("four", Number(4), "en"), ("five", Number(5), "en"),
    ("six", Number(6), "en"), ("seven", Number(7), "en"), ("eight", Number(8), "en"), ("nine", Number(9), "en"), ("ten", Number(10), "en"),
    ("eleven", Number(11), "en"), ("twelve", Number(12), "en"),
    ("let's", Stop, "en"), ("lets", Stop, "en"), ("meet", Stop, "en"), ("meeting", Stop, "en"), ("call", Stop, "en"), ("can", Stop, "en"),
    ("we", Stop, "en"), ("do", Stop, "en"), ("the", Stop, "en"), ("a", Stop, "en"), ("is", Stop, "en"), ("are", Stop, "en"), ("on", Stop, "en"),
    ("of", Stop, "en"), ("it", Stop, "en"), ("be", Stop, "en"), ("will", Stop, "en"), ("when", Stop, "en"), ("what", Stop, "en"), ("how", Stop, "en"),
    ("about", Stop, "en"), ("works", Stop, "en"), ("work", Stop, "en"), ("for", Stop, "en"), ("you", Stop, "en"), ("me", Stop, "en"), ("us", Stop, "en"),
    ("our", Stop, "en"), ("your", Stop, "en"), ("please", Stop, "en"), ("ok", Stop, "en"), ("okay", Stop, "en"), ("sure", Stop, "en"),
    ("deadline", Stop, "en"), ("due", Stop, "en"), ("launch", Stop, "en"), ("webinar", Stop, "en"), ("standup", Stop, "en"), ("sync", Stop, "en"),
    ("session", Stop, "en"), ("event", Stop, "en"), ("starts", Stop, "en"), ("start", Stop, "en"), ("ends", Stop, "en"), ("end", Stop, "en"),
    ("scheduled", Stop, "en"), ("planned", Stop, "en"), ("set", Stop, "en"), ("there", Stop, "en"), ("here", Stop, "en"), ("my", Stop, "en"),
    ("that", Stop, "en"), ("then", Stop, "en"), ("than", Stop, "en"), ("or", Stop, "en"), ("if", Stop, "en"), ("hi", Stop, "en"), ("hey", Stop, "en"),
    ("thanks", Stop, "en"), ("tomorrow's", Stop, "en"), ("does", Stop, "en"), ("did", Stop, "en"), ("should", Stop, "en"), ("could", Stop, "en"),
    ("would", Stop, "en"), ("just", Stop, "en"), ("also", Stop, "en"), ("maybe", Stop, "en"), ("instead", Stop, "en"), ("still", Stop, "en"),
    ("everyone", Stop, "en"), ("team", Stop, "en"), ("all", Stop, "en"), ("hands", Stop, "en"), ("review", Stop, "en"), ("demo", Stop, "en"),
    ("live", Stop, "en"), ("stream", Stop, "en"), ("going", Stop, "en"), ("please", Stop, "en"), ("reminder", Stop, "en"), ("join", Stop, "en"),
    // ─────────────── 中文（简繁） ───────────────
    ("一月", Month(1), "zh"), ("二月", Month(2), "zh"), ("三月", Month(3), "zh"), ("四月", Month(4), "zh"), ("五月", Month(5), "zh"),
    ("六月", Month(6), "zh"), ("七月", Month(7), "zh"), ("八月", Month(8), "zh"), ("九月", Month(9), "zh"), ("十月", Month(10), "zh"),
    ("十一月", Month(11), "zh"), ("十二月", Month(12), "zh"),
    ("星期一", Weekday(1), "zh"), ("星期二", Weekday(2), "zh"), ("星期三", Weekday(3), "zh"), ("星期四", Weekday(4), "zh"), ("星期五", Weekday(5), "zh"),
    ("星期六", Weekday(6), "zh"), ("星期日", Weekday(7), "zh"), ("星期天", Weekday(7), "zh"),
    ("周一", Weekday(1), "zh"), ("周二", Weekday(2), "zh"), ("周三", Weekday(3), "zh"), ("周四", Weekday(4), "zh"), ("周五", Weekday(5), "zh"),
    ("周六", Weekday(6), "zh"), ("周日", Weekday(7), "zh"), ("周天", Weekday(7), "zh"),
    ("週一", Weekday(1), "zh"), ("週二", Weekday(2), "zh"), ("週三", Weekday(3), "zh"), ("週四", Weekday(4), "zh"), ("週五", Weekday(5), "zh"),
    ("週六", Weekday(6), "zh"), ("週日", Weekday(7), "zh"), ("週天", Weekday(7), "zh"),
    ("礼拜一", Weekday(1), "zh"), ("礼拜二", Weekday(2), "zh"), ("礼拜三", Weekday(3), "zh"), ("礼拜四", Weekday(4), "zh"), ("礼拜五", Weekday(5), "zh"),
    ("礼拜六", Weekday(6), "zh"), ("礼拜天", Weekday(7), "zh"), ("礼拜日", Weekday(7), "zh"),
    ("禮拜一", Weekday(1), "zh"), ("禮拜二", Weekday(2), "zh"), ("禮拜三", Weekday(3), "zh"), ("禮拜四", Weekday(4), "zh"), ("禮拜五", Weekday(5), "zh"),
    ("禮拜六", Weekday(6), "zh"), ("禮拜天", Weekday(7), "zh"), ("禮拜日", Weekday(7), "zh"),
    ("今天", RelDay(0), "zh"), ("今日", RelDay(0), "zh"), ("明天", RelDay(1), "zh"), ("明日", RelDay(1), "zh"), ("后天", RelDay(2), "zh"),
    ("後天", RelDay(2), "zh"), ("昨天", RelDay(-1), "zh"), ("前天", RelDay(-2), "zh"), ("大后天", RelDay(3), "zh"), ("大後天", RelDay(3), "zh"),
    ("今晚", RelDayPeriod(0, Evening), "zh"), ("今早", RelDayPeriod(0, Morning), "zh"), ("今晨", RelDayPeriod(0, Morning), "zh"),
    ("明早", RelDayPeriod(1, Morning), "zh"), ("明晨", RelDayPeriod(1, Morning), "zh"), ("明晚", RelDayPeriod(1, Evening), "zh"),
    ("今天晚上", RelDayPeriod(0, Evening), "zh"), ("明天早上", RelDayPeriod(1, Morning), "zh"), ("明天晚上", RelDayPeriod(1, Evening), "zh"),
    ("下", NextWeek, "zh"), ("下个", NextWeek, "zh"), ("下個", NextWeek, "zh"), ("这", ThisWeek, "zh"), ("這", ThisWeek, "zh"), ("本", ThisWeek, "zh"),
    ("上", LastWeek, "zh"), ("上个", LastWeek, "zh"), ("上個", LastWeek, "zh"),
    ("上午", Period(Am), "zh"), ("早上", Period(Morning), "zh"), ("早晨", Period(Morning), "zh"), ("清晨", Period(Morning), "zh"), ("早", Period(Morning), "zh"),
    ("中午", Period(Midday), "zh"), ("下午", Period(Pm), "zh"), ("午后", Period(Afternoon), "zh"), ("傍晚", Period(Evening), "zh"),
    ("晚上", Period(Evening), "zh"), ("晚", Period(Evening), "zh"), ("夜里", Period(Night), "zh"), ("夜裡", Period(Night), "zh"), ("夜晚", Period(Night), "zh"),
    ("深夜", Period(Night), "zh"), ("半夜", Period(Night), "zh"), ("凌晨", Period(SmallHours), "zh"),
    ("正午", Noon, "zh"), ("午夜", Midnight, "zh"),
    ("点", ClockAfter, "zh"), ("點", ClockAfter, "zh"), ("点钟", ClockAfter, "zh"), ("點鐘", ClockAfter, "zh"), ("时", ClockAfter, "zh"),
    ("分", MinuteAfter, "zh"), ("半", HalfAfter, "zh"), ("日", DayMark, "zh"), ("号", DayMark, "zh"), ("號", DayMark, "zh"), ("月", MonthMark, "zh"),
    ("年", YearMark, "zh"), ("后", RelLater, "zh"), ("後", RelLater, "zh"), ("以后", RelLater, "zh"), ("以後", RelLater, "zh"), ("之后", RelLater, "zh"),
    ("之後", RelLater, "zh"), ("前", RelAgo, "zh"), ("以前", RelAgo, "zh"), ("小时", HourUnit, "zh"), ("小時", HourUnit, "zh"), ("个小时", HourUnit, "zh"),
    ("個小時", HourUnit, "zh"), ("钟头", HourUnit, "zh"), ("鐘頭", HourUnit, "zh"), ("分钟", MinuteUnit, "zh"), ("分鐘", MinuteUnit, "zh"),
    ("半小时", HalfHour, "zh"), ("半小時", HalfHour, "zh"), ("半个小时", HalfHour, "zh"), ("半個小時", HalfHour, "zh"), ("一个小时", OneHour, "zh"), ("一個小時", OneHour, "zh"),
    ("到", RangeSep, "zh"), ("至", RangeSep, "zh"), ("从", From, "zh"), ("從", From, "zh"), ("和", And, "zh"), ("跟", And, "zh"),
    ("时间", ZoneAfter, "zh"), ("時間", ZoneAfter, "zh"), ("在", PlaceIn, "zh"),
    ("几点", TargetAsk, "zh"), ("幾點", TargetAsk, "zh"), ("是几点", TargetAsk, "zh"), ("是幾點", TargetAsk, "zh"), ("的几点", TargetAsk, "zh"),
    ("换成", TargetTo, "zh"), ("換成", TargetTo, "zh"), ("换算成", TargetTo, "zh"), ("換算成", TargetTo, "zh"), ("转成", TargetTo, "zh"), ("轉成", TargetTo, "zh"),
    ("一", Number(1), "zh"), ("二", Number(2), "zh"), ("两", Number(2), "zh"), ("兩", Number(2), "zh"), ("三", Number(3), "zh"), ("四", Number(4), "zh"),
    ("五", Number(5), "zh"), ("六", Number(6), "zh"), ("七", Number(7), "zh"), ("八", Number(8), "zh"), ("九", Number(9), "zh"), ("十", Number(10), "zh"),
    ("十一", Number(11), "zh"), ("十二", Number(12), "zh"),
    ("会议", Stop, "zh"), ("會議", Stop, "zh"), ("会", Stop, "zh"), ("开会", Stop, "zh"), ("開會", Stop, "zh"), ("定在", Stop, "zh"), ("是", Stop, "zh"),
    ("的", Stop, "zh"), ("吧", Stop, "zh"), ("吗", Stop, "zh"), ("嗎", Stop, "zh"), ("呢", Stop, "zh"), ("我们", Stop, "zh"), ("我們", Stop, "zh"),
    ("见", Stop, "zh"), ("見", Stop, "zh"), ("截止", Stop, "zh"), ("开始", Stop, "zh"), ("開始", Stop, "zh"), ("电话", Stop, "zh"), ("電話", Stop, "zh"),
    ("周", Filler, "zh"), ("週", Filler, "zh"), ("星期", Filler, "zh"), ("礼拜", Filler, "zh"), ("禮拜", Filler, "zh"),
    // ─────────────── 日本語 ───────────────
    ("月曜日", Weekday(1), "ja"), ("月曜", Weekday(1), "ja"), ("火曜日", Weekday(2), "ja"), ("火曜", Weekday(2), "ja"), ("水曜日", Weekday(3), "ja"),
    ("水曜", Weekday(3), "ja"), ("木曜日", Weekday(4), "ja"), ("木曜", Weekday(4), "ja"), ("金曜日", Weekday(5), "ja"), ("金曜", Weekday(5), "ja"),
    ("土曜日", Weekday(6), "ja"), ("土曜", Weekday(6), "ja"), ("日曜日", Weekday(7), "ja"), ("日曜", Weekday(7), "ja"),
    ("きょう", RelDay(0), "ja"), ("本日", RelDay(0), "ja"), ("あした", RelDay(1), "ja"), ("あす", RelDay(1), "ja"), ("明後日", RelDay(2), "ja"),
    ("あさって", RelDay(2), "ja"), ("昨日", RelDay(-1), "ja"), ("昨夜", RelDayPeriod(-1, Night), "ja"), ("きのう", RelDay(-1), "ja"), ("今夜", RelDayPeriod(0, Evening), "ja"),
    ("翌朝", NextDayPeriod(Morning), "ja"), ("翌日", NextDay, "ja"), ("次の日", NextDay, "ja"),
    ("the next morning", NextDayPeriod(Morning), "en"), ("the following day", NextDay, "en"), ("le lendemain", NextDay, "fr"),
    ("今晩", RelDayPeriod(0, Evening), "ja"), ("今朝", RelDayPeriod(0, Morning), "ja"), ("明朝", RelDayPeriod(1, Morning), "ja"),
    ("来週の", NextWeek, "ja"), ("来週", NextWeek, "ja"), ("今週の", ThisWeek, "ja"), ("今週", ThisWeek, "ja"), ("先週の", LastWeek, "ja"), ("先週", LastWeek, "ja"),
    // 「次の / 次回の」也是「下一」（此前只有来週の）。
    ("次の", NextWeek, "ja"), ("次回の", NextWeek, "ja"),
    ("午前", Period(Am), "ja"), ("午後", Period(Pm), "ja"), ("朝", Period(Morning), "ja"), ("昼", Period(Midday), "ja"), ("夕方", Period(Evening), "ja"),
    ("夜", Period(Evening), "ja"), ("深夜", Period(Night), "ja"), ("未明", Period(SmallHours), "ja"), ("正午", Noon, "ja"),
    ("時", ClockAfter, "ja"), ("時半", HalfAfter, "ja"), ("から", RangeSep, "ja"), ("まで", Stop, "ja"), ("時間後", RelLater, "ja"), ("後", RelLater, "ja"),
    ("時間", HourUnit, "ja"), ("分", MinuteUnit, "ja"), ("日本時間", ZoneAfter, "ja"), ("時間", ZoneAfter, "ja"), ("では何時", TargetAsk, "ja"),
    ("は何時", TargetAsk, "ja"), ("で何時", TargetAsk, "ja"), ("何時", TargetAsk, "ja"), ("の", Stop, "ja"), ("で", Stop, "ja"), ("に", Stop, "ja"),
    ("は", Stop, "ja"), ("ですか", Stop, "ja"), ("大丈夫", Stop, "ja"), ("会議", Stop, "ja"), ("ミーティング", Stop, "ja"), ("打ち合わせ", Stop, "ja"),
    ("お願いします", Stop, "ja"), ("です", Stop, "ja"), ("ます", Stop, "ja"), ("でしょうか", Stop, "ja"),
    // ─────────────── 한국어 ───────────────
    ("월요일", Weekday(1), "ko"), ("화요일", Weekday(2), "ko"), ("수요일", Weekday(3), "ko"), ("목요일", Weekday(4), "ko"), ("금요일", Weekday(5), "ko"),
    ("토요일", Weekday(6), "ko"), ("일요일", Weekday(7), "ko"),
    ("오늘", RelDay(0), "ko"), ("내일", RelDay(1), "ko"), ("모레", RelDay(2), "ko"), ("어제", RelDay(-1), "ko"), ("오늘 밤", RelDayPeriod(0, Evening), "ko"),
    ("내일 아침", RelDayPeriod(1, Morning), "ko"), ("다음 주", NextWeek, "ko"), ("다음주", NextWeek, "ko"), ("다음", NextWeek, "ko"), ("이번 주", ThisWeek, "ko"), ("이번주", ThisWeek, "ko"),
    ("지난주", LastWeek, "ko"), ("지난 주", LastWeek, "ko"),
    ("오전", Period(Am), "ko"), ("오후", Period(Pm), "ko"), ("아침", Period(Morning), "ko"), ("점심", Period(Midday), "ko"), ("저녁", Period(Evening), "ko"),
    ("밤", Period(Night), "ko"), ("새벽", Period(SmallHours), "ko"), ("정오", Noon, "ko"), ("자정", Midnight, "ko"),
    ("시", ClockAfter, "ko"), ("분", MinuteAfter, "ko"), ("반", HalfAfter, "ko"), ("일", DayMark, "ko"), ("월", MonthMark, "ko"), ("년", YearMark, "ko"),
    ("부터", RangeSep, "ko"), ("까지", Stop, "ko"), ("후", RelLater, "ko"), ("뒤", RelLater, "ko"), ("시간", HourUnit, "ko"), ("분", MinuteUnit, "ko"),
    ("시간", ZoneAfter, "ko"), ("몇 시", TargetAsk, "ko"), ("는 몇 시", TargetAsk, "ko"), ("은 몇 시", TargetAsk, "ko"), ("에", Stop, "ko"),
    ("에서", Stop, "ko"), ("회의", Stop, "ko"), ("미팅", Stop, "ko"), ("괜찮아요", Stop, "ko"), ("어때요", Stop, "ko"),
    // ─────────────── Deutsch ───────────────
    ("januar", Month(1), "de"), ("jänner", Month(1), "de"), ("februar", Month(2), "de"), ("märz", Month(3), "de"), ("maerz", Month(3), "de"), ("mär", Month(3), "de"),
    ("mai", Month(5), "de"), ("juni", Month(6), "de"), ("juli", Month(7), "de"), ("oktober", Month(10), "de"), ("okt", Month(10), "de"),
    ("dezember", Month(12), "de"), ("dez", Month(12), "de"),
    ("montag", Weekday(1), "de"), ("dienstag", Weekday(2), "de"), ("mittwoch", Weekday(3), "de"), ("donnerstag", Weekday(4), "de"),
    ("freitag", Weekday(5), "de"), ("samstag", Weekday(6), "de"), ("sonnabend", Weekday(6), "de"), ("sonntag", Weekday(7), "de"),
    ("heute", RelDay(0), "de"), ("morgen", RelDay(1), "de"), ("übermorgen", RelDay(2), "de"), ("gestern", RelDay(-1), "de"), ("vorgestern", RelDay(-2), "de"),
    ("heute abend", RelDayPeriod(0, Evening), "de"), ("heute morgen", RelDayPeriod(0, Morning), "de"), ("heute nachmittag", RelDayPeriod(0, Afternoon), "de"),
    ("morgen früh", RelDayPeriod(1, Morning), "de"), ("morgen abend", RelDayPeriod(1, Evening), "de"), ("morgen nachmittag", RelDayPeriod(1, Afternoon), "de"),
    ("nächste Woche", NextWeek, "de"), ("nächsten", NextWeek, "de"), ("nächste", NextWeek, "de"), ("kommenden", NextWeek, "de"), ("diesen", ThisWeek, "de"), ("letzten", LastWeek, "de"),
    ("vormittags", Period(Am), "de"), ("vorm", Period(Am), "de"), ("nachmittags", Period(Afternoon), "de"), ("nachm", Period(Pm), "de"),
    ("morgens", Period(Morning), "de"), ("früh", Period(Morning), "de"), ("mittags", Period(Midday), "de"), ("abends", Period(Evening), "de"),
    ("am abend", Period(Evening), "de"), ("am morgen", Period(Morning), "de"), ("am nachmittag", Period(Afternoon), "de"), ("nachts", Period(Night), "de"),
    ("mittag", Noon, "de"), ("mitternacht", Midnight, "de"),
    ("um", ClockBefore, "de"), ("gegen", ClockBefore, "de"), ("ab", ClockBefore, "de"), ("uhr", ClockAfter, "de"), ("halb", HalfBefore, "de"),
    ("in", RelIn, "de"), ("stunden", HourUnit, "de"), ("stunde", HourUnit, "de"), ("std", HourUnit, "de"), ("minuten", MinuteUnit, "de"),
    ("eine stunde", OneHour, "de"), ("einer stunde", OneHour, "de"), ("einer halben stunde", HalfHour, "de"), ("halbe stunde", HalfHour, "de"),
    ("bis", RangeSep, "de"), ("von", From, "de"), ("zwischen", Between, "de"), ("und", And, "de"), ("zeit", ZoneAfter, "de"), ("in", PlaceIn, "de"), ("aus", PlaceIn, "de"), ("auf den", PlaceInArticle, "de"), ("im", PlaceInArticle, "de"),
    ("wie spät ist das in", TargetAsk, "de"), ("wie spät ist es in", TargetAsk, "de"), ("wie spät in", TargetAsk, "de"), ("wieviel uhr in", TargetAsk, "de"), ("in", TargetTo, "de"), ("nach", TargetTo, "de"),
    ("treffen", Stop, "de"), ("wir", Stop, "de"), ("uns", Stop, "de"), ("am", Stop, "de"), ("der", Stop, "de"), ("die", Stop, "de"), ("das", Stop, "de"),
    ("ist", Stop, "de"), ("es", Stop, "de"), ("passt", Stop, "de"), ("termin", Stop, "de"), ("besprechung", Stop, "de"), ("anruf", Stop, "de"),
    ("können", Stop, "de"), ("koennen", Stop, "de"), ("geht", Stop, "de"), ("wann", Stop, "de"), ("dann", Stop, "de"), ("im", Stop, "de"), ("ein", Stop, "de"),
    // ─────────────── Français ───────────────
    ("janvier", Month(1), "fr"), ("janv", Month(1), "fr"), ("février", Month(2), "fr"), ("févr", Month(2), "fr"), ("fév", Month(2), "fr"),
    ("mars", Month(3), "fr"), ("avril", Month(4), "fr"), ("avr", Month(4), "fr"), ("juin", Month(6), "fr"), ("juillet", Month(7), "fr"),
    ("juil", Month(7), "fr"), ("août", Month(8), "fr"), ("aout", Month(8), "fr"), ("septembre", Month(9), "fr"), ("octobre", Month(10), "fr"),
    ("novembre", Month(11), "fr"), ("décembre", Month(12), "fr"), ("déc", Month(12), "fr"),
    ("lundi", Weekday(1), "fr"), ("mardi", Weekday(2), "fr"), ("mercredi", Weekday(3), "fr"), ("jeudi", Weekday(4), "fr"), ("vendredi", Weekday(5), "fr"),
    ("samedi", Weekday(6), "fr"), ("dimanche", Weekday(7), "fr"),
    ("aujourd'hui", RelDay(0), "fr"), ("demain", RelDay(1), "fr"), ("après-demain", RelDay(2), "fr"), ("apres-demain", RelDay(2), "fr"),
    ("après demain", RelDay(2), "fr"), ("hier", RelDay(-1), "fr"), ("avant-hier", RelDay(-2), "fr"), ("ce soir", RelDayPeriod(0, Evening), "fr"),
    ("ce matin", RelDayPeriod(0, Morning), "fr"), ("cet après-midi", RelDayPeriod(0, Afternoon), "fr"), ("demain matin", RelDayPeriod(1, Morning), "fr"),
    ("demain soir", RelDayPeriod(1, Evening), "fr"), ("prochain", NextAfter, "fr"), ("prochaine", NextAfter, "fr"),
    ("du matin", Period(Am), "fr"), ("le matin", Period(Morning), "fr"), ("matin", Period(Morning), "fr"), ("de l'après-midi", Period(Afternoon), "fr"),
    ("après-midi", Period(Afternoon), "fr"), ("du soir", Period(Evening), "fr"), ("le soir", Period(Evening), "fr"), ("soir", Period(Evening), "fr"),
    ("de la nuit", Period(Night), "fr"), ("midi", Noon, "fr"), ("minuit", Midnight, "fr"),
    ("à", ClockBefore, "fr"), ("vers", ClockBefore, "fr"), ("h", ClockAfter, "fr"), ("heures", ClockAfter, "fr"), ("heure", ClockAfter, "fr"),
    ("et demie", HalfAfter, "fr"), ("dans", RelIn, "fr"), ("minutes", MinuteUnit, "fr"), ("une heure", OneHour, "fr"), ("une demi-heure", HalfHour, "fr"),
    ("une demi heure", HalfHour, "fr"), ("de", From, "fr"), ("à", RangeSep, "fr"), ("jusqu'à", RangeSep, "fr"), ("entre", Between, "fr"), ("et", And, "fr"),
    ("de", ZoneBefore, "fr"), ("heure de", ZoneBefore, "fr"), ("heure d'", ZoneBefore, "fr"), ("à", PlaceIn, "fr"), ("au", PlaceInArticle, "fr"), ("aux", PlaceInArticle, "fr"), ("en", PlaceIn, "fr"),
    ("quelle heure sera-t-il à", TargetAsk, "fr"), ("quelle heure à", TargetAsk, "fr"), ("quelle heure est-il à", TargetAsk, "fr"), ("à", TargetTo, "fr"),
    ("rendez-vous", Stop, "fr"), ("réunion", Stop, "fr"), ("appel", Stop, "fr"), ("le", Stop, "fr"), ("par", Stop, "fr"), ("la", Stop, "fr"), ("les", Stop, "fr"),
    ("est", Stop, "fr"), ("c'est", Stop, "fr"), ("on", Stop, "fr"), ("se", Stop, "fr"), ("voit", Stop, "fr"), ("pour", Stop, "fr"), ("nous", Stop, "fr"),
    ("vous", Stop, "fr"), ("ça", Stop, "fr"), ("ca", Stop, "fr"), ("marche", Stop, "fr"), ("du", Stop, "fr"), ("des", Stop, "fr"), ("un", Stop, "fr"), ("une", Stop, "fr"),
    // ─────────────── Español ───────────────
    ("enero", Month(1), "es"), ("ene", Month(1), "es"), ("febrero", Month(2), "es"), ("marzo", Month(3), "es"), ("abril", Month(4), "es"), ("abr", Month(4), "es"),
    ("mayo", Month(5), "es"), ("junio", Month(6), "es"), ("julio", Month(7), "es"), ("agosto", Month(8), "es"), ("septiembre", Month(9), "es"),
    ("setiembre", Month(9), "es"), ("octubre", Month(10), "es"), ("noviembre", Month(11), "es"), ("diciembre", Month(12), "es"), ("dic", Month(12), "es"),
    ("lunes", Weekday(1), "es"), ("martes", Weekday(2), "es"), ("miércoles", Weekday(3), "es"), ("jueves", Weekday(4), "es"), ("viernes", Weekday(5), "es"),
    ("sábado", Weekday(6), "es"), ("domingo", Weekday(7), "es"),
    ("hoy", RelDay(0), "es"), ("mañana", RelDay(1), "es"), ("pasado mañana", RelDay(2), "es"), ("ayer", RelDay(-1), "es"), ("anteayer", RelDay(-2), "es"),
    ("esta noche", RelDayPeriod(0, Evening), "es"), ("esta tarde", RelDayPeriod(0, Afternoon), "es"), ("esta mañana", RelDayPeriod(0, Morning), "es"),
    ("mañana por la mañana", RelDayPeriod(1, Morning), "es"), ("mañana por la tarde", RelDayPeriod(1, Afternoon), "es"),
    ("mañana por la noche", RelDayPeriod(1, Evening), "es"), ("próximo", NextAfter, "es"), ("que viene", NextAfter, "es"), ("el próximo", NextWeek, "es"),
    ("de la mañana", Period(Am), "es"), ("por la mañana", Period(Morning), "es"), ("de la tarde", Period(Afternoon), "es"), ("por la tarde", Period(Afternoon), "es"),
    ("de la noche", Period(Evening), "es"), ("por la noche", Period(Evening), "es"), ("de la madrugada", Period(SmallHours), "es"),
    ("mediodía", Noon, "es"), ("medianoche", Midnight, "es"),
    ("son las", ClockBefore, "es"), ("es la", ClockBefore, "es"),
    ("a las", ClockBefore, "es"), ("a la", ClockBefore, "es"), ("sobre las", ClockBefore, "es"), ("hs", ClockAfter, "es"), ("horas", ClockAfter, "es"),
    ("y media", HalfAfter, "es"), ("en", RelIn, "es"), ("dentro de", RelIn, "es"), ("minutos", MinuteUnit, "es"), ("una hora", OneHour, "es"),
    ("media hora", HalfHour, "es"), ("desde", From, "es"), ("de", From, "es"), ("hasta", RangeSep, "es"), ("a", RangeSep, "es"), ("entre", Between, "es"),
    ("y", And, "es"), ("de", ZoneBefore, "es"), ("hora de", ZoneBefore, "es"), ("hora en", ZoneBefore, "es"), ("en", PlaceIn, "es"), ("a", PlaceIn, "es"),
    ("qué hora será en", TargetAsk, "es"), ("qué hora es en", TargetAsk, "es"), ("qué hora en", TargetAsk, "es"), ("que hora en", TargetAsk, "es"), ("en", TargetTo, "es"),
    ("podemos", Stop, "es"), ("hablar", Stop, "es"), ("el", Stop, "es"), ("la", Stop, "es"), ("los", Stop, "es"), ("las", Stop, "es"), ("reunión", Stop, "es"),
    ("llamada", Stop, "es"), ("nos", Stop, "es"), ("vemos", Stop, "es"), ("es", Stop, "es"), ("te", Stop, "es"), ("parece", Stop, "es"), ("bien", Stop, "es"),
    ("para", Stop, "es"), ("un", Stop, "es"), ("una", Stop, "es"), ("del", Stop, "es"), ("que", Stop, "es"), ("correr", Stop, "es"),
    // ─────────────── Português ───────────────
    ("janeiro", Month(1), "pt"), ("fevereiro", Month(2), "pt"), ("fev", Month(2), "pt"), ("março", Month(3), "pt"), ("abril", Month(4), "pt"),
    ("maio", Month(5), "pt"), ("junho", Month(6), "pt"), ("julho", Month(7), "pt"), ("agosto", Month(8), "pt"), ("setembro", Month(9), "pt"),
    ("outubro", Month(10), "pt"), ("out", Month(10), "pt"), ("novembro", Month(11), "pt"), ("dezembro", Month(12), "pt"),
    // 巴西活动页的月份缩写（「18 ago - 2025」）；共用写法在表首保留葡语归属。
    ("abr", Month(4), "pt"), ("mai", Month(5), "pt"), ("ago", Month(8), "pt"), ("dez", Month(12), "pt"),
    ("segunda-feira", Weekday(1), "pt"), ("segunda", Weekday(1), "pt"), ("terça-feira", Weekday(2), "pt"), ("terça", Weekday(2), "pt"),
    ("quarta-feira", Weekday(3), "pt"), ("quarta", Weekday(3), "pt"), ("quinta-feira", Weekday(4), "pt"), ("quinta", Weekday(4), "pt"),
    ("sexta-feira", Weekday(5), "pt"), ("sexta", Weekday(5), "pt"), ("sábado", Weekday(6), "pt"), ("domingo", Weekday(7), "pt"),
    ("hoje", RelDay(0), "pt"), ("amanhã", RelDay(1), "pt"), ("depois de amanhã", RelDay(2), "pt"), ("ontem", RelDay(-1), "pt"), ("anteontem", RelDay(-2), "pt"),
    ("hoje à noite", RelDayPeriod(0, Evening), "pt"), ("esta noite", RelDayPeriod(0, Evening), "pt"), ("hoje de manhã", RelDayPeriod(0, Morning), "pt"),
    ("amanhã de manhã", RelDayPeriod(1, Morning), "pt"), ("amanhã à tarde", RelDayPeriod(1, Afternoon), "pt"), ("amanhã à noite", RelDayPeriod(1, Evening), "pt"),
    ("que vem", NextAfter, "pt"), ("próxima", NextWeek, "pt"), ("próximo", NextWeek, "pt"),
    ("da manhã", Period(Am), "pt"), ("de manhã", Period(Morning), "pt"), ("da tarde", Period(Afternoon), "pt"), ("à tarde", Period(Afternoon), "pt"),
    ("da noite", Period(Evening), "pt"), ("à noite", Period(Evening), "pt"), ("da madrugada", Period(SmallHours), "pt"), ("meio-dia", Noon, "pt"),
    ("meio dia", Noon, "pt"), ("meia-noite", Midnight, "pt"), ("meia noite", Midnight, "pt"),
    ("às", ClockBefore, "pt"), ("as", ClockBefore, "pt"), ("h", ClockAfter, "pt"), ("hrs", ClockAfter, "pt"), ("e meia", HalfAfter, "pt"),
    ("em", RelIn, "pt"), ("daqui a", RelIn, "pt"), ("minutos", MinuteUnit, "pt"), ("uma hora", OneHour, "pt"), ("meia hora", HalfHour, "pt"),
    ("das", From, "pt"), ("até", RangeSep, "pt"), ("às", RangeSep, "pt"), ("entre", Between, "pt"), ("e", And, "pt"),
    ("horário de", ZoneBefore, "pt"), ("hora de", ZoneBefore, "pt"), ("em", PlaceIn, "pt"), ("no", PlaceInArticle, "pt"), ("na", PlaceInArticle, "pt"), ("nos", PlaceInArticle, "pt"), ("nas", PlaceInArticle, "pt"), ("que horas em", TargetAsk, "pt"),
    ("que horas são em", TargetAsk, "pt"), ("em", TargetTo, "pt"),
    ("reunião", Stop, "pt"), ("vamos", Stop, "pt"), ("conversar", Stop, "pt"), ("o", Stop, "pt"), ("os", Stop, "pt"), ("às", Stop, "pt"), ("uma", Stop, "pt"),
    ("um", Stop, "pt"), ("do", Stop, "pt"), ("da", Stop, "pt"), ("na", Stop, "pt"), ("no", Stop, "pt"), ("pode", Stop, "pt"), ("ser", Stop, "pt"),
    // ─────────────── Italiano ───────────────
    ("gennaio", Month(1), "it"), ("gen", Month(1), "it"), ("febbraio", Month(2), "it"), ("marzo", Month(3), "it"), ("aprile", Month(4), "it"),
    ("maggio", Month(5), "it"), ("mag", Month(5), "it"), ("giugno", Month(6), "it"), ("giu", Month(6), "it"), ("luglio", Month(7), "it"), ("lug", Month(7), "it"),
    ("agosto", Month(8), "it"), ("settembre", Month(9), "it"), ("set", Month(9), "it"), ("ottobre", Month(10), "it"), ("ott", Month(10), "it"),
    ("novembre", Month(11), "it"), ("dicembre", Month(12), "it"),
    ("lunedì", Weekday(1), "it"), ("martedì", Weekday(2), "it"), ("mercoledì", Weekday(3), "it"), ("giovedì", Weekday(4), "it"), ("venerdì", Weekday(5), "it"),
    ("sabato", Weekday(6), "it"), ("domenica", Weekday(7), "it"),
    ("oggi", RelDay(0), "it"), ("domani", RelDay(1), "it"), ("dopodomani", RelDay(2), "it"), ("ieri", RelDay(-1), "it"), ("l'altro ieri", RelDay(-2), "it"),
    ("questa sera", RelDayPeriod(0, Evening), "it"), ("stasera", RelDayPeriod(0, Evening), "it"), ("stamattina", RelDayPeriod(0, Morning), "it"), ("oggi pomeriggio", RelDayPeriod(0, Afternoon), "it"),
    ("domani mattina", RelDayPeriod(1, Morning), "it"), ("domattina", RelDayPeriod(1, Morning), "it"), ("domani pomeriggio", RelDayPeriod(1, Afternoon), "it"),
    ("domani sera", RelDayPeriod(1, Evening), "it"), ("prossimo", NextAfter, "it"), ("prossima", NextAfter, "it"),
    ("prossimo", NextWeek, "it"), ("prossima", NextWeek, "it"), ("volgende week", NextWeek, "nl"), ("w następną", NextWeek, "pl"),
    ("di mattina", Period(Am), "it"), ("del mattino", Period(Am), "it"), ("mattina", Period(Morning), "it"), ("del pomeriggio", Period(Afternoon), "it"),
    ("di pomeriggio", Period(Afternoon), "it"), ("pomeriggio", Period(Afternoon), "it"), ("di sera", Period(Evening), "it"), ("sera", Period(Evening), "it"),
    ("di notte", Period(Night), "it"), ("mezzogiorno", Noon, "it"), ("mezzanotte", Midnight, "it"),
    ("alle", ClockBefore, "it"), ("all'", ClockBefore, "it"), ("verso le", ClockBefore, "it"), ("ore", ClockBefore, "it"), ("e mezza", HalfAfter, "it"),
    ("e mezzo", HalfAfter, "it"), ("tra", RelIn, "it"), ("fra", RelIn, "it"), ("ore", HourUnit, "it"), ("ora", HourUnit, "it"), ("minuti", MinuteUnit, "it"),
    ("un'ora", OneHour, "it"), ("mezz'ora", HalfHour, "it"), ("mezzora", HalfHour, "it"), ("dalle", From, "it"), ("alle", RangeSep, "it"),
    ("fino alle", RangeSep, "it"), ("tra le", Between, "it"), ("e", And, "it"), ("di", ZoneBefore, "it"), ("ora di", ZoneBefore, "it"), ("orario di", ZoneBefore, "it"), ("a", PlaceIn, "it"), ("in", PlaceIn, "it"), ("nel", PlaceInArticle, "it"), ("nella", PlaceInArticle, "it"), ("negli", PlaceInArticle, "it"), ("nei", PlaceInArticle, "it"), ("nelle", PlaceInArticle, "it"),
    ("che ore sono a", TargetAsk, "it"), ("che ora sarà a", TargetAsk, "it"), ("che ora è a", TargetAsk, "it"), ("che ore a", TargetAsk, "it"), ("a", TargetTo, "it"),
    ("riunione", Stop, "it"), ("chiamata", Stop, "it"), ("ci", Stop, "it"), ("vediamo", Stop, "it"), ("il", Stop, "it"), ("lo", Stop, "it"), ("la", Stop, "it"),
    ("va", Stop, "it"), ("bene", Stop, "it"), ("per", Stop, "it"), ("di", Stop, "it"), ("un", Stop, "it"), ("una", Stop, "it"), ("possiamo", Stop, "it"),
    ("sentirci", Stop, "it"), ("è", Stop, "it"),
    // ─────────────── Nederlands ───────────────
    ("januari", Month(1), "nl"), ("februari", Month(2), "nl"), ("maart", Month(3), "nl"), ("mrt", Month(3), "nl"), ("mei", Month(5), "nl"),
    ("augustus", Month(8), "nl"), ("oktober", Month(10), "nl"),
    ("maandag", Weekday(1), "nl"), ("dinsdag", Weekday(2), "nl"), ("woensdag", Weekday(3), "nl"), ("donderdag", Weekday(4), "nl"),
    ("vrijdag", Weekday(5), "nl"), ("zaterdag", Weekday(6), "nl"), ("zondag", Weekday(7), "nl"),
    ("vandaag", RelDay(0), "nl"), ("morgen", RelDay(1), "nl"), ("overmorgen", RelDay(2), "nl"), ("gisteren", RelDay(-1), "nl"), ("eergisteren", RelDay(-2), "nl"),
    ("vanavond", RelDayPeriod(0, Evening), "nl"), ("vanmiddag", RelDayPeriod(0, Afternoon), "nl"), ("vanochtend", RelDayPeriod(0, Morning), "nl"),
    ("vanmorgen", RelDayPeriod(0, Morning), "nl"), ("morgenochtend", RelDayPeriod(1, Morning), "nl"), ("morgenmiddag", RelDayPeriod(1, Afternoon), "nl"),
    ("morgenavond", RelDayPeriod(1, Evening), "nl"), ("volgende", NextWeek, "nl"), ("komende", NextWeek, "nl"), ("deze", ThisWeek, "nl"),
    ("vorige", LastWeek, "nl"), ("afgelopen", LastWeek, "nl"),
    ("'s ochtends", Period(Morning), "nl"), ("s ochtends", Period(Morning), "nl"), ("'s morgens", Period(Morning), "nl"), ("'s middags", Period(Afternoon), "nl"),
    ("s middags", Period(Afternoon), "nl"), ("'s avonds", Period(Evening), "nl"), ("s avonds", Period(Evening), "nl"), ("'s nachts", Period(Night), "nl"),
    ("middag", Noon, "nl"), ("middernacht", Midnight, "nl"),
    ("om", ClockBefore, "nl"), ("rond", ClockBefore, "nl"), ("uur", ClockAfter, "nl"), ("u", ClockAfter, "nl"), ("half", HalfBefore, "nl"),
    ("over", RelIn, "nl"), ("uur", HourUnit, "nl"), ("minuten", MinuteUnit, "nl"), ("een uur", OneHour, "nl"), ("een half uur", HalfHour, "nl"),
    ("half uur", HalfHour, "nl"), ("van", From, "nl"), ("tot", RangeSep, "nl"), ("tussen", Between, "nl"), ("en", And, "nl"),
    ("tijd", ZoneAfter, "nl"), ("in", PlaceIn, "nl"), ("hoe laat is het dan in", TargetAsk, "nl"), ("hoe laat is het in", TargetAsk, "nl"), ("hoe laat in", TargetAsk, "nl"), ("in", TargetTo, "nl"),
    ("open", Stop, "nl"), ("winkel", Stop, "nl"), ("vergadering", Stop, "nl"), ("afspraak", Stop, "nl"), ("zullen", Stop, "nl"), ("we", Stop, "nl"), ("afspreken", Stop, "nl"), ("de", Stop, "nl"),
    ("het", Stop, "nl"), ("is", Stop, "nl"), ("een", Stop, "nl"), ("op", Stop, "nl"), ("kunnen", Stop, "nl"), ("bellen", Stop, "nl"), ("prima", Stop, "nl"),
    // ─────────────── Polski ───────────────
    ("styczeń", Month(1), "pl"), ("stycznia", Month(1), "pl"), ("sty", Month(1), "pl"), ("luty", Month(2), "pl"), ("lutego", Month(2), "pl"), ("lut", Month(2), "pl"),
    ("marzec", Month(3), "pl"), ("marca", Month(3), "pl"), ("kwiecień", Month(4), "pl"), ("kwietnia", Month(4), "pl"), ("kwi", Month(4), "pl"),
    ("maj", Month(5), "pl"), ("maja", Month(5), "pl"), ("czerwiec", Month(6), "pl"), ("czerwca", Month(6), "pl"), ("cze", Month(6), "pl"),
    ("lipiec", Month(7), "pl"), ("lipca", Month(7), "pl"), ("lip", Month(7), "pl"), ("sierpień", Month(8), "pl"), ("sierpnia", Month(8), "pl"),
    ("sie", Month(8), "pl"), ("wrzesień", Month(9), "pl"), ("września", Month(9), "pl"), ("wrz", Month(9), "pl"), ("październik", Month(10), "pl"),
    ("października", Month(10), "pl"), ("paź", Month(10), "pl"), ("listopad", Month(11), "pl"), ("listopada", Month(11), "pl"), ("lis", Month(11), "pl"),
    ("grudzień", Month(12), "pl"), ("grudnia", Month(12), "pl"), ("gru", Month(12), "pl"),
    ("poniedziałek", Weekday(1), "pl"), ("wtorek", Weekday(2), "pl"), ("środa", Weekday(3), "pl"), ("środę", Weekday(3), "pl"), ("czwartek", Weekday(4), "pl"),
    ("piątek", Weekday(5), "pl"), ("sobota", Weekday(6), "pl"), ("sobotę", Weekday(6), "pl"), ("niedziela", Weekday(7), "pl"), ("niedzielę", Weekday(7), "pl"),
    ("dzisiaj", RelDay(0), "pl"), ("dziś", RelDay(0), "pl"), ("jutro", RelDay(1), "pl"), ("pojutrze", RelDay(2), "pl"), ("wczoraj", RelDay(-1), "pl"),
    ("przedwczoraj", RelDay(-2), "pl"), ("dziś wieczorem", RelDayPeriod(0, Evening), "pl"), ("jutro rano", RelDayPeriod(1, Morning), "pl"),
    ("jutro wieczorem", RelDayPeriod(1, Evening), "pl"), ("w przyszły", NextWeek, "pl"), ("w przyszłą", NextWeek, "pl"), ("przyszły", NextWeek, "pl"),
    ("rano", Period(Morning), "pl"), ("przed południem", Period(Am), "pl"), ("po południu", Period(Afternoon), "pl"), ("wieczorem", Period(Evening), "pl"),
    ("w nocy", Period(Night), "pl"), ("w południe", Noon, "pl"), ("południe", Noon, "pl"), ("o północy", Midnight, "pl"), ("północ", Midnight, "pl"),
    ("o godzinie", ClockBefore, "pl"), ("o godz", ClockBefore, "pl"), ("godz", ClockBefore, "pl"), ("o", ClockBefore, "pl"),
    ("godz.", ClockBefore, "pl"), ("o godz.", ClockBefore, "pl"),
    ("za", RelIn, "pl"), ("godziny", HourUnit, "pl"), ("godzin", HourUnit, "pl"), ("godzinę", HourUnit, "pl"), ("minut", MinuteUnit, "pl"),
    ("minuty", MinuteUnit, "pl"), ("pół godziny", HalfHour, "pl"), ("od", From, "pl"), ("do", RangeSep, "pl"), ("między", Between, "pl"), ("i", And, "pl"),
    ("czasu", ZoneBefore, "pl"), ("w", PlaceIn, "pl"), ("która godzina jest w", TargetAsk, "pl"), ("która godzina w", TargetAsk, "pl"), ("w", TargetTo, "pl"),
    ("spotkanie", Stop, "pl"), ("spotkajmy", Stop, "pl"), ("się", Stop, "pl"), ("rozmowa", Stop, "pl"), ("jest", Stop, "pl"), ("na", Stop, "pl"), ("czy", Stop, "pl"),
    ("pasuje", Stop, "pl"), ("możemy", Stop, "pl"), ("porozmawiać", Stop, "pl"),
    // ─────────────── Русский ───────────────
    ("январь", Month(1), "ru"), ("января", Month(1), "ru"), ("янв", Month(1), "ru"), ("февраль", Month(2), "ru"), ("февраля", Month(2), "ru"),
    ("фев", Month(2), "ru"), ("март", Month(3), "ru"), ("марта", Month(3), "ru"), ("апрель", Month(4), "ru"), ("апреля", Month(4), "ru"),
    ("апр", Month(4), "ru"), ("май", Month(5), "ru"), ("мая", Month(5), "ru"), ("июнь", Month(6), "ru"), ("июня", Month(6), "ru"), ("июль", Month(7), "ru"),
    ("июля", Month(7), "ru"), ("август", Month(8), "ru"), ("августа", Month(8), "ru"), ("авг", Month(8), "ru"), ("сентябрь", Month(9), "ru"),
    ("сентября", Month(9), "ru"), ("сен", Month(9), "ru"), ("сент", Month(9), "ru"), ("октябрь", Month(10), "ru"), ("октября", Month(10), "ru"),
    ("окт", Month(10), "ru"), ("ноябрь", Month(11), "ru"), ("ноября", Month(11), "ru"), ("ноя", Month(11), "ru"), ("декабрь", Month(12), "ru"),
    ("декабря", Month(12), "ru"), ("дек", Month(12), "ru"),
    ("понедельник", Weekday(1), "ru"), ("вторник", Weekday(2), "ru"), ("среда", Weekday(3), "ru"), ("среду", Weekday(3), "ru"), ("четверг", Weekday(4), "ru"),
    ("пятница", Weekday(5), "ru"), ("пятницу", Weekday(5), "ru"), ("суббота", Weekday(6), "ru"), ("субботу", Weekday(6), "ru"), ("воскресенье", Weekday(7), "ru"),
    ("сегодня", RelDay(0), "ru"), ("завтра", RelDay(1), "ru"), ("послезавтра", RelDay(2), "ru"), ("вчера", RelDay(-1), "ru"), ("позавчера", RelDay(-2), "ru"),
    ("сегодня вечером", RelDayPeriod(0, Evening), "ru"), ("завтра утром", RelDayPeriod(1, Morning), "ru"), ("завтра вечером", RelDayPeriod(1, Evening), "ru"),
    ("на следующей неделе", NextAfter, "ru"), ("в следующий", NextWeek, "ru"), ("в следующую", NextWeek, "ru"), ("следующий", NextWeek, "ru"), ("в эту", ThisWeek, "ru"), ("в этот", ThisWeek, "ru"),
    ("утра", Period(Am), "ru"), ("утром", Period(Morning), "ru"), ("дня", Period(Afternoon), "ru"), ("днём", Period(Afternoon), "ru"), ("днем", Period(Afternoon), "ru"),
    ("вечера", Period(Evening), "ru"), ("вечером", Period(Evening), "ru"), ("ночи", Period(Night), "ru"), ("ночью", Period(Night), "ru"),
    ("полдень", Noon, "ru"), ("в полдень", Noon, "ru"), ("полночь", Midnight, "ru"), ("в полночь", Midnight, "ru"),
    ("в", ClockBefore, "ru"), ("к", ClockBefore, "ru"), ("около", ClockBefore, "ru"), ("ч", ClockAfter, "ru"), ("часов", ClockAfter, "ru"),
    ("часа", ClockAfter, "ru"), ("через", RelIn, "ru"), ("часа", HourUnit, "ru"), ("часов", HourUnit, "ru"), ("час", OneHour, "ru"), ("минут", MinuteUnit, "ru"),
    ("минуты", MinuteUnit, "ru"), ("полчаса", HalfHour, "ru"), ("назад", RelAgo, "ru"), ("с", From, "ru"), ("до", RangeSep, "ru"), ("между", Between, "ru"),
    ("и", And, "ru"), ("том же", Stop, "ru"), ("по", ZoneBefore, "ru"), ("по времени", ZoneBefore, "ru"), ("в", PlaceIn, "ru"), ("на", PlaceIn, "ru"), ("сколько будет в", TargetAsk, "ru"),
    ("сколько в", TargetAsk, "ru"), ("сколько времени в", TargetAsk, "ru"), ("который час в", TargetAsk, "ru"), ("в", TargetTo, "ru"),
    ("встреча", Stop, "ru"), ("созвон", Stop, "ru"), ("давайте", Stop, "ru"), ("на", Stop, "ru"), ("это", Stop, "ru"), ("удобно", Stop, "ru"),
    ("времени", Stop, "ru"), ("время", Stop, "ru"),
    // ─────────────── Türkçe ───────────────
    ("ocak", Month(1), "tr"), ("şubat", Month(2), "tr"), ("şub", Month(2), "tr"), ("mart", Month(3), "tr"), ("nisan", Month(4), "tr"), ("nis", Month(4), "tr"),
    ("mayıs", Month(5), "tr"), ("haziran", Month(6), "tr"), ("haz", Month(6), "tr"), ("temmuz", Month(7), "tr"), ("tem", Month(7), "tr"),
    ("ağustos", Month(8), "tr"), ("ağu", Month(8), "tr"), ("eylül", Month(9), "tr"), ("eyl", Month(9), "tr"), ("ekim", Month(10), "tr"),
    ("kasım", Month(11), "tr"), ("kas", Month(11), "tr"), ("aralık", Month(12), "tr"),
    ("pazartesi", Weekday(1), "tr"), ("salı", Weekday(2), "tr"), ("çarşamba", Weekday(3), "tr"), ("perşembe", Weekday(4), "tr"), ("cuma", Weekday(5), "tr"),
    ("cumartesi", Weekday(6), "tr"), ("pazar", Weekday(7), "tr"),
    ("bugün", RelDay(0), "tr"), ("yarın", RelDay(1), "tr"), ("öbür gün", RelDay(2), "tr"), ("dün", RelDay(-1), "tr"), ("evvelsi gün", RelDay(-2), "tr"), ("bu akşam", RelDayPeriod(0, Evening), "tr"),
    ("bu sabah", RelDayPeriod(0, Morning), "tr"), ("yarın sabah", RelDayPeriod(1, Morning), "tr"), ("yarın akşam", RelDayPeriod(1, Evening), "tr"),
    ("gelecek hafta", NextWeek, "tr"), ("gelecek", NextWeek, "tr"), ("önümüzdeki", NextWeek, "tr"), ("haftaya", NextWeek, "tr"), ("bu", ThisWeek, "tr"), ("geçen", LastWeek, "tr"),
    ("sabah", Period(Morning), "tr"), ("öğleden önce", Period(Am), "tr"), ("öğleden sonra", Period(Afternoon), "tr"), ("akşam", Period(Evening), "tr"),
    ("gece", Period(Night), "tr"), ("öğlen", Noon, "tr"), ("öğle", Noon, "tr"), ("gece yarısı", Midnight, "tr"),
    ("saat", ClockBefore, "tr"), ("sonra", RelLater, "tr"), ("saat", HourUnit, "tr"), ("dakika", MinuteUnit, "tr"), ("bir saat", OneHour, "tr"),
    ("yarım saat", HalfHour, "tr"), ("buçuk", HalfAfter, "tr"), ("önce", RelAgo, "tr"), ("ile", RangeSep, "tr"), ("arası", Stop, "tr"), ("ve", And, "tr"),
    ("saati", ZoneAfter, "tr"), ("saatiyle", ZoneAfter, "tr"), ("saatine göre", ZoneAfter, "tr"), ("saat kaç", TargetAsk, "tr"),
    ("toplantı", Stop, "tr"), ("görüşme", Stop, "tr"), ("görüşelim", Stop, "tr"), ("uygun", Stop, "tr"), ("mu", Stop, "tr"), ("mi", Stop, "tr"), ("de", Stop, "tr"),
    ("da", Stop, "tr"),
    // ─────────────── Tiếng Việt ───────────────
    ("thứ hai", Weekday(1), "vi"), ("thứ 2", Weekday(1), "vi"), ("thứ ba", Weekday(2), "vi"), ("thứ 3", Weekday(2), "vi"), ("thứ tư", Weekday(3), "vi"),
    ("thứ 4", Weekday(3), "vi"), ("thứ năm", Weekday(4), "vi"), ("thứ 5", Weekday(4), "vi"), ("thứ sáu", Weekday(5), "vi"), ("thứ 6", Weekday(5), "vi"),
    ("thứ bảy", Weekday(6), "vi"), ("thứ 7", Weekday(6), "vi"), ("chủ nhật", Weekday(7), "vi"),
    ("hôm nay", RelDay(0), "vi"), ("ngày mai", RelDay(1), "vi"), ("mai", RelDay(1), "vi"), ("ngày kia", RelDay(2), "vi"), ("ngày mốt", RelDay(2), "vi"), ("hôm qua", RelDay(-1), "vi"),
    ("tối nay", RelDayPeriod(0, Evening), "vi"), ("sáng nay", RelDayPeriod(0, Morning), "vi"), ("chiều nay", RelDayPeriod(0, Afternoon), "vi"),
    ("sáng mai", RelDayPeriod(1, Morning), "vi"), ("chiều mai", RelDayPeriod(1, Afternoon), "vi"), ("tối mai", RelDayPeriod(1, Evening), "vi"),
    ("tuần sau", NextAfter, "vi"), ("tuần tới", NextAfter, "vi"), ("này", Stop, "vi"),
    ("sáng", Period(Morning), "vi"), ("buổi sáng", Period(Morning), "vi"), ("trưa", Period(Midday), "vi"), ("chiều", Period(Afternoon), "vi"),
    ("buổi chiều", Period(Afternoon), "vi"), ("tối", Period(Evening), "vi"), ("buổi tối", Period(Evening), "vi"), ("đêm", Period(Night), "vi"),
    ("giữa trưa", Noon, "vi"), ("nửa đêm", Midnight, "vi"),
    ("lúc", ClockBefore, "vi"), ("vào lúc", ClockBefore, "vi"), ("vào", ClockBefore, "vi"), ("giờ", ClockAfter, "vi"), ("g", ClockAfter, "vi"),
    ("h", ClockAfter, "vi"), ("phút", MinuteAfter, "vi"), ("rưỡi", HalfAfter, "vi"), ("ngày", DayBefore, "vi"), ("tháng", MonthBefore, "vi"),
    ("năm", YearMark, "vi"), ("nữa", RelLater, "vi"), ("sau", RelIn, "vi"), ("tiếng", HourUnit, "vi"), ("giờ", HourUnit, "vi"), ("phút", MinuteUnit, "vi"),
    ("nửa tiếng", HalfHour, "vi"), ("một tiếng", OneHour, "vi"), ("trước", RelAgo, "vi"), ("từ", From, "vi"), ("đến", RangeSep, "vi"), ("tới", RangeSep, "vi"),
    ("và", And, "vi"), ("giờ", ZoneBefore, "vi"), ("theo giờ", ZoneBefore, "vi"), ("ở", PlaceIn, "vi"), ("tại", PlaceIn, "vi"), ("là mấy giờ", TargetAsk, "vi"),
    ("mấy giờ", TargetAsk, "vi"), ("họp", Stop, "vi"), ("cuộc họp", Stop, "vi"), ("cuộc hẹn", Stop, "vi"), ("gặp", Stop, "vi"), ("nhé", Stop, "vi"), ("được", Stop, "vi"),
    ("không", Stop, "vi"), ("chúng ta", Stop, "vi"), ("mình", Stop, "vi"), ("bạn", Stop, "vi"),
    // ─────────────── Bahasa Indonesia ───────────────
    ("januari", Month(1), "id"), ("februari", Month(2), "id"), ("maret", Month(3), "id"), ("april", Month(4), "id"), ("mei", Month(5), "id"),
    ("juni", Month(6), "id"), ("juli", Month(7), "id"), ("agustus", Month(8), "id"), ("agu", Month(8), "id"), ("september", Month(9), "id"),
    ("oktober", Month(10), "id"), ("november", Month(11), "id"), ("desember", Month(12), "id"),
    ("senin", Weekday(1), "id"), ("selasa", Weekday(2), "id"), ("rabu", Weekday(3), "id"), ("kamis", Weekday(4), "id"), ("jumat", Weekday(5), "id"),
    ("jum'at", Weekday(5), "id"), ("sabtu", Weekday(6), "id"), ("hari minggu", Weekday(7), "id"), ("minggu", Weekday(7), "id"),
    ("hari ini", RelDay(0), "id"), ("besok", RelDay(1), "id"), ("lusa", RelDay(2), "id"), ("besok lusa", RelDay(2), "id"), ("kemarin", RelDay(-1), "id"), ("malam ini", RelDayPeriod(0, Evening), "id"),
    ("nanti malam", RelDayPeriod(0, Evening), "id"), ("pagi ini", RelDayPeriod(0, Morning), "id"), ("besok pagi", RelDayPeriod(1, Morning), "id"),
    ("besok sore", RelDayPeriod(1, Afternoon), "id"), ("besok malam", RelDayPeriod(1, Evening), "id"), ("depan", NextAfter, "id"),
    ("minggu depan", NextAfter, "id"), ("ini", Stop, "id"),
    ("pagi", Period(Morning), "id"), ("siang", Period(Midday), "id"), ("sore", Period(Afternoon), "id"), ("malam", Period(Evening), "id"),
    ("dini hari", Period(SmallHours), "id"), ("tengah hari", Noon, "id"), ("tengah malam", Midnight, "id"),
    ("pukul", ClockBefore, "id"), ("jam", ClockBefore, "id"), ("lagi", RelLater, "id"), ("dalam", RelIn, "id"), ("jam", HourUnit, "id"), ("menit", MinuteUnit, "id"),
    ("setengah jam", HalfHour, "id"), ("satu jam", OneHour, "id"), ("sejam", OneHour, "id"), ("yang lalu", RelAgo, "id"), ("dari", From, "id"),
    // （旧版认、新引擎漏的）：西法葡「en / dans / em 2 horas」的小时单位（此前只当「几点」，读成 2 点）；
    // 量在后的「以前」（vor / hace / il y a / há）；意荷波韩的「以前」（fa / geleden / temu / 전）；「一个半小时」；「через минуту」。
    ("horas", HourUnit, "es"), ("hora", HourUnit, "es"), ("heures", HourUnit, "fr"), ("heure", HourUnit, "fr"), ("horas", HourUnit, "pt"),
    ("hora", HourUnit, "pt"), ("vor", RelAgoBefore, "de"), ("hace", RelAgoBefore, "es"), ("il y a", RelAgoBefore, "fr"), ("há", RelAgoBefore, "pt"),
    ("fa", RelAgo, "it"), ("geleden", RelAgo, "nl"), ("temu", RelAgo, "pl"), ("전", RelAgo, "ko"),
    ("个半小时", HourAndHalfUnit, "zh"), ("個半小時", HourAndHalfUnit, "zh"), ("минуту", OneMinute, "ru"),
    // 量与方向的封闭补表。
    ("полтора часа", FixedMinutes(90), "ru"), ("час", HourUnit, "ru"), ("godzina", HourUnit, "pl"),
    ("içinde", RelLater, "tr"), ("trong", RelIn, "vi"),
    // 明确表示时长的动词与名词。
    ("took", DurationBefore, "en"), ("durará", DurationBefore, "es"), ("durera", DurationBefore, "fr"),
    ("durerà", DurationBefore, "it"), ("vai durar", DurationBefore, "pt"), ("durar", DurationBefore, "pt"),
    ("duur", DurationBefore, "nl"), ("trwał", DurationBefore, "pl"), ("длительность", DurationBefore, "ru"),
    ("sürüyor", DurationAfter, "tr"), ("thời lượng", DurationBefore, "vi"), ("dài", DurationBefore, "vi"),
    ("bắt đầu", ClockContextBefore, "vi"), ("kém", ClockContextAfter, "vi"),
    // 前天（一昨日 / おととい / 그저께 / 그제）与以天计的相对日期的「天」。
    ("一昨日", RelDay(-2), "ja"), ("おととい", RelDay(-2), "ja"), ("그저께", RelDay(-2), "ko"), ("그제", RelDay(-2), "ko"),
    // 当天之内的截止（旧版 23:59）；星期缩写；西葡的「下周」。
    ("今天之内", RelDayEnd(0), "zh"), ("今天之內", RelDayEnd(0), "zh"), ("明天之内", RelDayEnd(1), "zh"), ("明天之內", RelDayEnd(1), "zh"),
    ("今日中に", RelDayEnd(0), "ja"), ("明日中に", RelDayEnd(1), "ja"), ("今日中", RelDayEnd(0), "ja"), ("明日中", RelDayEnd(1), "ja"),
    ("오늘 중으로", RelDayEnd(0), "ko"), ("내일 중으로", RelDayEnd(1), "ko"), ("日付が変わるまでに", Idiom("dayend"), "ja"),
    ("mo", WeekdayAbbr(1), "de"), ("di", WeekdayAbbr(2), "de"), ("mi", WeekdayAbbr(3), "de"), ("do", WeekdayAbbr(4), "de"), ("fr", WeekdayAbbr(5), "de"),
    ("sa", WeekdayAbbr(6), "de"), ("so", WeekdayAbbr(7), "de"), ("lun", WeekdayAbbr(1), "fr"), ("mar", WeekdayAbbr(2), "fr"), ("mer", WeekdayAbbr(3), "fr"),
    ("jeu", WeekdayAbbr(4), "fr"), ("ven", WeekdayAbbr(5), "fr"), ("sam", WeekdayAbbr(6), "fr"), ("dim", WeekdayAbbr(7), "fr"), ("lun", WeekdayAbbr(1), "es"),
    ("mar", WeekdayAbbr(2), "es"), ("mie", WeekdayAbbr(3), "es"), ("jue", WeekdayAbbr(4), "es"), ("vie", WeekdayAbbr(5), "es"), ("sab", WeekdayAbbr(6), "es"),
    ("dom", WeekdayAbbr(7), "es"), ("seg", WeekdayAbbr(1), "pt"), ("ter", WeekdayAbbr(2), "pt"), ("qua", WeekdayAbbr(3), "pt"), ("qui", WeekdayAbbr(4), "pt"),
    ("sex", WeekdayAbbr(5), "pt"), ("sab", WeekdayAbbr(6), "pt"), ("dom", WeekdayAbbr(7), "pt"), ("lun", WeekdayAbbr(1), "it"), ("mar", WeekdayAbbr(2), "it"),
    ("mer", WeekdayAbbr(3), "it"), ("gio", WeekdayAbbr(4), "it"), ("ven", WeekdayAbbr(5), "it"), ("sab", WeekdayAbbr(6), "it"), ("dom", WeekdayAbbr(7), "it"),
    ("ma", WeekdayAbbr(1), "nl"), ("di", WeekdayAbbr(2), "nl"), ("wo", WeekdayAbbr(3), "nl"), ("do", WeekdayAbbr(4), "nl"), ("vr", WeekdayAbbr(5), "nl"),
    ("za", WeekdayAbbr(6), "nl"), ("zo", WeekdayAbbr(7), "nl"), ("пн", WeekdayAbbr(1), "ru"), ("вт", WeekdayAbbr(2), "ru"), ("ср", WeekdayAbbr(3), "ru"),
    ("чт", WeekdayAbbr(4), "ru"), ("пт", WeekdayAbbr(5), "ru"), ("сб", WeekdayAbbr(6), "ru"), ("вс", WeekdayAbbr(7), "ru"), ("pon", WeekdayAbbr(1), "pl"),
    ("wt", WeekdayAbbr(2), "pl"), ("sr", WeekdayAbbr(3), "pl"), ("czw", WeekdayAbbr(4), "pl"), ("pt", WeekdayAbbr(5), "pl"), ("sob", WeekdayAbbr(6), "pl"),
    ("nd", WeekdayAbbr(7), "pl"), ("pzt", WeekdayAbbr(1), "tr"), ("sal", WeekdayAbbr(2), "tr"), ("car", WeekdayAbbr(3), "tr"), ("per", WeekdayAbbr(4), "tr"),
    ("cum", WeekdayAbbr(5), "tr"), ("cmt", WeekdayAbbr(6), "tr"), ("paz", WeekdayAbbr(7), "tr"),
    ("la proxima semana", NextWeek, "es"), ("proxima semana", NextWeek, "es"), ("la semana que viene", NextWeek, "es"),
    // 「este viernes / esta sexta」是这周（此前 este 被当成地名，查到了 Santo Domingo Este）；午夜前的截止。
    ("este", ThisWeek, "es"), ("esta", ThisWeek, "es"), ("este", Stop, "es"), ("esta", Stop, "es"), ("este", ThisWeek, "pt"), ("esta", ThisWeek, "pt"),
    ("este", Stop, "pt"), ("esta", Stop, "pt"), ("antes da meia-noite", Idiom("midnight"), "pt"), ("antes da meia noite", Idiom("midnight"), "pt"),
    ("antes de la medianoche", Idiom("midnight"), "es"),
    // 中午前的截止（「by noon at 3pm」此前把 noon 单独读成 12 点，矛盾没说出来）。
    ("by noon", Idiom("noon"), "en"), ("before noon", Idiom("noon"), "en"), ("by midday", Idiom("noon"), "en"), ("before midday", Idiom("noon"), "en"),
    ("vor mittag", Idiom("noon"), "de"), ("antes do meio-dia", Idiom("noon"), "pt"), ("antes do meio dia", Idiom("noon"), "pt"),
    ("a proxima semana", NextWeek, "pt"), ("proxima semana", NextWeek, "pt"), ("semana que vem", NextWeek, "pt"), ("el", Filler, "es"),
    ("day", DayUnit, "en"), ("days", DayUnit, "en"), ("天", DayUnit, "zh"), ("日", DayUnit, "ja"), ("일", DayUnit, "ko"),
    ("tag", DayUnit, "de"), ("tage", DayUnit, "de"), ("tagen", DayUnit, "de"), ("jour", DayUnit, "fr"), ("jours", DayUnit, "fr"),
    ("dia", DayUnit, "es"), ("dias", DayUnit, "es"), ("dia", DayUnit, "pt"), ("dias", DayUnit, "pt"), ("giorno", DayUnit, "it"),
    ("giorni", DayUnit, "it"), ("dag", DayUnit, "nl"), ("dagen", DayUnit, "nl"), ("dzien", DayUnit, "pl"), ("dni", DayUnit, "pl"),
    ("день", DayUnit, "ru"), ("дня", DayUnit, "ru"), ("дней", DayUnit, "ru"), ("gun", DayUnit, "tr"), ("ngay", DayUnit, "vi"), ("hari", DayUnit, "id"),
    ("sampai", RangeSep, "id"), ("hingga", RangeSep, "id"), ("s.d.", RangeSep, "id"), ("dan", And, "id"), ("waktu", ZoneBefore, "id"), ("di", PlaceIn, "id"),
    ("jam berapa di", TargetAsk, "id"), ("pukul berapa di", TargetAsk, "id"),
    ("jam berapa waktunya di", TargetAsk, "id"), ("pukul berapa waktunya di", TargetAsk, "id"),
    ("jam berapa", TargetAsk, "id"), ("pukul berapa", TargetAsk, "id"),
    ("rapat", Stop, "id"), ("pertemuan", Stop, "id"), ("kita", Stop, "id"),
    ("ketemu", Stop, "id"), ("bisa", Stop, "id"), ("ya", Stop, "id"), ("hari", Stop, "id"), ("tanggal", Stop, "id"),
    // ─────────────── 时长、习语、刻与半、数词、连接词、本地时间、Unix 线索 ───────────────
    // en
    ("for", DurationBefore, "en"), ("lasting", DurationBefore, "en"), ("lasts", DurationBefore, "en"), ("duration", DurationBefore, "en"),
    ("long", DurationAfter, "en"),
    ("eod", Idiom("eod"), "en"), ("end of day", Idiom("eod"), "en"), ("end of the day", Idiom("eod"), "en"), ("cob", Idiom("eod"), "en"),
    ("eob", Idiom("eod"), "en"), ("close of business", Idiom("eod"), "en"), ("end of business", Idiom("eod"), "en"),
    ("by midnight", Idiom("midnight"), "en"), ("before midnight", Idiom("midnight"), "en"),
    ("quarter past", ClockShift(15), "en"), ("a quarter past", ClockShift(15), "en"), ("quarter after", ClockShift(15), "en"),
    ("quarter to", ClockShift(-15), "en"), ("a quarter to", ClockShift(-15), "en"), ("half past", ClockShift(30), "en"),
    ("past", Past, "en"), ("after", Past, "en"), ("to", ToHour, "en"),
    ("twenty", Number(20), "en"), ("twenty-five", Number(25), "en"), ("twenty five", Number(25), "en"),
    ("local time", LocalZone, "en"), ("in local time", LocalZone, "en"), ("my time", LocalZone, "en"), ("our time", LocalZone, "en"),
    ("my local time", LocalZone, "en"), ("here", LocalZone, "en"),
    ("unix", UnixCue, "en"), ("epoch", UnixCue, "en"), ("timestamp", UnixCue, "en"), ("ts", UnixCue, "en"), ("unix time", UnixCue, "en"),
    ("or", Connector, "en"), ("which is", Connector, "en"), ("i.e.", Connector, "en"), ("i.e", Connector, "en"), ("ie", Connector, "en"),
    ("that is", Connector, "en"), ("aka", Connector, "en"), ("equals", Connector, "en"), ("same as", Connector, "en"),
    // zh
    ("持续", DurationBefore, "zh"), ("持續", DurationBefore, "zh"), ("历时", DurationBefore, "zh"), ("歷時", DurationBefore, "zh"),
    ("时长", DurationBefore, "zh"), ("時長", DurationBefore, "zh"), ("大约", ClockBefore, "zh"), ("大概", ClockBefore, "zh"), ("左右", Stop, "zh"),
    ("下班前", Idiom("eod"), "zh"), ("下班之前", Idiom("eod"), "zh"), ("中午前", Idiom("before_noon"), "zh"), ("中午之前", Idiom("before_noon"), "zh"),
    ("午夜前", Idiom("midnight"), "zh"), ("午夜之前", Idiom("midnight"), "zh"), ("半夜前", Idiom("midnight"), "zh"),
    ("一刻", AfterMinutes(15), "zh"), ("三刻", AfterMinutes(45), "zh"),
    ("本地时间", LocalZone, "zh"), ("本地時間", LocalZone, "zh"), ("我这边", LocalZone, "zh"), ("我這邊", LocalZone, "zh"),
    ("我们这边", LocalZone, "zh"), ("我們這邊", LocalZone, "zh"), ("我这里", LocalZone, "zh"), ("我這裡", LocalZone, "zh"),
    ("时间戳", UnixCue, "zh"), ("時間戳", UnixCue, "zh"),
    ("即", Connector, "zh"), ("也就是", Connector, "zh"), ("或", Connector, "zh"), ("也就是说", Connector, "zh"), ("也就是說", Connector, "zh"),
    ("二十", Number(20), "zh"), ("二十五", Number(25), "zh"),
    // ja
    ("真夜中", Midnight, "ja"), ("ごろ", Stop, "ja"), ("頃", Stop, "ja"),
    ("終業まで", Idiom("eod"), "ja"), ("終業時間まで", Idiom("eod"), "ja"), ("営業終了まで", Idiom("eod"), "ja"), ("正午まで", Idiom("noon"), "ja"),
    ("こちらの時間", LocalZone, "ja"), ("私の時間", LocalZone, "ja"), ("タイムスタンプ", UnixCue, "ja"),
    ("つまり", Connector, "ja"), ("すなわち", Connector, "ja"), ("または", Connector, "ja"), ("もしくは", Connector, "ja"),
    // ko
    ("동안", DurationAfter, "ko"), ("소요", DurationBefore, "ko"), ("쯤", Stop, "ko"), ("경", Stop, "ko"),
    ("퇴근 전", Idiom("eod"), "ko"), ("퇴근 전까지", Idiom("eod"), "ko"), ("업무 종료 전", Idiom("eod"), "ko"), ("정오까지", Idiom("noon"), "ko"),
    ("자정까지", Idiom("midnight"), "ko"), ("자정 전", Idiom("midnight"), "ko"),
    ("한", Number(1), "ko"), ("두", Number(2), "ko"), ("세", Number(3), "ko"), ("네", Number(4), "ko"), ("다섯", Number(5), "ko"),
    ("여섯", Number(6), "ko"), ("일곱", Number(7), "ko"), ("여덟", Number(8), "ko"), ("아홉", Number(9), "ko"), ("열", Number(10), "ko"),
    ("열한", Number(11), "ko"), ("열두", Number(12), "ko"),
    ("우리 시간", LocalZone, "ko"), ("여기 시간", LocalZone, "ko"), ("제 시간", LocalZone, "ko"), ("타임스탬프", UnixCue, "ko"),
    ("즉", Connector, "ko"), ("또는", Connector, "ko"), ("혹은", Connector, "ko"),
    // de
    ("dauert", DurationBefore, "de"), ("dauer", DurationBefore, "de"), ("lang", DurationAfter, "de"),
    ("bis feierabend", Idiom("eod"), "de"), ("bis geschäftsschluss", Idiom("eod"), "de"), ("bis dienstschluss", Idiom("eod"), "de"),
    ("bis mittag", Idiom("noon"), "de"), ("bis mitternacht", Idiom("midnight"), "de"),
    ("viertel nach", ClockShift(15), "de"), ("viertel vor", ClockShift(-15), "de"), ("dreiviertel", ClockShift(-15), "de"), ("drei viertel", ClockShift(-15), "de"),
    ("nach", Past, "de"), ("vor", ToHour, "de"),
    ("eins", Number(1), "de"), ("ein", Number(1), "de"), ("eine", Number(1), "de"), ("zwei", Number(2), "de"), ("drei", Number(3), "de"),
    ("vier", Number(4), "de"), ("fünf", Number(5), "de"), ("sechs", Number(6), "de"), ("sieben", Number(7), "de"), ("acht", Number(8), "de"),
    ("neun", Number(9), "de"), ("zehn", Number(10), "de"), ("elf", Number(11), "de"), ("zwölf", Number(12), "de"), ("zwanzig", Number(20), "de"),
    ("fünfundzwanzig", Number(25), "de"),
    ("meiner zeit", LocalZone, "de"), ("unserer zeit", LocalZone, "de"), ("bei mir", LocalZone, "de"), ("bei uns", LocalZone, "de"),
    ("zeitstempel", UnixCue, "de"),
    ("bzw.", Connector, "de"), ("bzw", Connector, "de"), ("beziehungsweise", Connector, "de"), ("also", Connector, "de"), ("oder", Connector, "de"),
    ("d.h.", Connector, "de"), ("d. h.", Connector, "de"), ("das heißt", Connector, "de"), ("sprich", Connector, "de"),
    // fr
    ("pendant", DurationBefore, "fr"), ("durée", DurationBefore, "fr"), ("dure", DurationBefore, "fr"), ("durant", DurationBefore, "fr"),
    ("avant la fin de journée", Idiom("eod"), "fr"), ("avant la fin de la journée", Idiom("eod"), "fr"), ("en fin de journée", Idiom("eod"), "fr"),
    ("fin de journée", Idiom("eod"), "fr"), ("avant midi", Idiom("noon"), "fr"), ("avant minuit", Idiom("midnight"), "fr"),
    ("et quart", AfterMinutes(15), "fr"), ("moins le quart", BeforeMinutes(15), "fr"), ("moins", Minus, "fr"),
    ("une", Number(1), "fr"), ("un", Number(1), "fr"), ("deux", Number(2), "fr"), ("trois", Number(3), "fr"), ("quatre", Number(4), "fr"),
    ("cinq", Number(5), "fr"), ("six", Number(6), "fr"), ("sept", Number(7), "fr"), ("huit", Number(8), "fr"), ("neuf", Number(9), "fr"),
    ("dix", Number(10), "fr"), ("onze", Number(11), "fr"), ("douze", Number(12), "fr"), ("vingt", Number(20), "fr"), ("vingt-cinq", Number(25), "fr"),
    ("mon heure", LocalZone, "fr"), ("chez moi", LocalZone, "fr"), ("chez nous", LocalZone, "fr"), ("notre heure", LocalZone, "fr"),
    ("horodatage", UnixCue, "fr"),
    ("soit", Connector, "fr"), ("c'est-à-dire", Connector, "fr"), ("c'est à dire", Connector, "fr"), ("ou", Connector, "fr"), ("autrement dit", Connector, "fr"),
    // es
    ("durante", DurationBefore, "es"), ("dura", DurationBefore, "es"), ("duración", DurationBefore, "es"),
    ("antes del cierre", Idiom("eod"), "es"), ("al final del día", Idiom("eod"), "es"), ("a fin de día", Idiom("eod"), "es"),
    ("antes de terminar el día", Idiom("eod"), "es"), ("antes del mediodía", Idiom("noon"), "es"), ("antes de medianoche", Idiom("midnight"), "es"),
    ("y cuarto", AfterMinutes(15), "es"), ("menos cuarto", BeforeMinutes(15), "es"), ("menos", Minus, "es"),
    ("una", Number(1), "es"), ("uno", Number(1), "es"), ("dos", Number(2), "es"), ("tres", Number(3), "es"), ("cuatro", Number(4), "es"),
    ("cinco", Number(5), "es"), ("seis", Number(6), "es"), ("siete", Number(7), "es"), ("ocho", Number(8), "es"), ("nueve", Number(9), "es"),
    ("diez", Number(10), "es"), ("once", Number(11), "es"), ("doce", Number(12), "es"), ("veinte", Number(20), "es"), ("veinticinco", Number(25), "es"),
    ("mi hora", LocalZone, "es"), ("nuestra hora", LocalZone, "es"), ("hora mía", LocalZone, "es"), ("marca de tiempo", UnixCue, "es"),
    ("o sea", Connector, "es"), ("es decir", Connector, "es"), ("o", Connector, "es"), ("ó", Connector, "es"),
    // pt
    ("durante", DurationBefore, "pt"), ("dura", DurationBefore, "pt"), ("duração", DurationBefore, "pt"),
    ("até o fim do dia", Idiom("eod"), "pt"), ("até o final do dia", Idiom("eod"), "pt"), ("fim do dia", Idiom("eod"), "pt"),
    ("final do expediente", Idiom("eod"), "pt"), ("até o meio-dia", Idiom("noon"), "pt"), ("até meio-dia", Idiom("noon"), "pt"),
    ("até a meia-noite", Idiom("midnight"), "pt"), ("até meia-noite", Idiom("midnight"), "pt"),
    ("e um quarto", AfterMinutes(15), "pt"), ("e quinze", AfterMinutes(15), "pt"),
    ("uma", Number(1), "pt"), ("um", Number(1), "pt"), ("duas", Number(2), "pt"), ("dois", Number(2), "pt"), ("três", Number(3), "pt"),
    ("quatro", Number(4), "pt"), ("cinco", Number(5), "pt"), ("seis", Number(6), "pt"), ("sete", Number(7), "pt"), ("oito", Number(8), "pt"),
    ("nove", Number(9), "pt"), ("dez", Number(10), "pt"), ("onze", Number(11), "pt"), ("doze", Number(12), "pt"), ("vinte", Number(20), "pt"),
    ("vinte e cinco", Number(25), "pt"),
    ("meu horário", LocalZone, "pt"), ("no meu horário", LocalZone, "pt"), ("nosso horário", LocalZone, "pt"), ("aqui", LocalZone, "pt"),
    ("ou seja", Connector, "pt"), ("isto é", Connector, "pt"), ("ou", Connector, "pt"),
    // it
    ("dura", DurationBefore, "it"), ("durata", DurationBefore, "it"), ("per", DurationBefore, "it"),
    ("entro fine giornata", Idiom("eod"), "it"), ("entro la fine della giornata", Idiom("eod"), "it"), ("a fine giornata", Idiom("eod"), "it"),
    ("entro mezzogiorno", Idiom("noon"), "it"), ("entro mezzanotte", Idiom("midnight"), "it"),
    ("e un quarto", AfterMinutes(15), "it"), ("meno un quarto", BeforeMinutes(15), "it"), ("meno", Minus, "it"),
    ("l'una", Number(1), "it"), ("una", Number(1), "it"), ("due", Number(2), "it"), ("tre", Number(3), "it"), ("quattro", Number(4), "it"),
    ("cinque", Number(5), "it"), ("sei", Number(6), "it"), ("sette", Number(7), "it"), ("otto", Number(8), "it"), ("nove", Number(9), "it"),
    ("dieci", Number(10), "it"), ("undici", Number(11), "it"), ("dodici", Number(12), "it"), ("venti", Number(20), "it"), ("venticinque", Number(25), "it"),
    ("mia ora", LocalZone, "it"), ("ora mia", LocalZone, "it"), ("da me", LocalZone, "it"), ("da noi", LocalZone, "it"), ("nostra ora", LocalZone, "it"),
    ("cioè", Connector, "it"), ("ossia", Connector, "it"), ("o", Connector, "it"), ("oppure", Connector, "it"), ("ovvero", Connector, "it"),
    // nl
    ("duurt", DurationBefore, "nl"), ("gedurende", DurationBefore, "nl"), ("lang", DurationAfter, "nl"),
    ("voor het einde van de werkdag", Idiom("eod"), "nl"), ("einde werkdag", Idiom("eod"), "nl"), ("eind van de dag", Idiom("eod"), "nl"),
    ("voor de middag", Idiom("noon"), "nl"), ("voor middernacht", Idiom("midnight"), "nl"),
    ("kwart over", ClockShift(15), "nl"), ("kwart voor", ClockShift(-15), "nl"), ("over", Past, "nl"), ("voor", ToHour, "nl"),
    ("een", Number(1), "nl"), ("één", Number(1), "nl"), ("twee", Number(2), "nl"), ("drie", Number(3), "nl"), ("vier", Number(4), "nl"),
    ("vijf", Number(5), "nl"), ("zes", Number(6), "nl"), ("zeven", Number(7), "nl"), ("acht", Number(8), "nl"), ("negen", Number(9), "nl"),
    ("tien", Number(10), "nl"), ("elf", Number(11), "nl"), ("twaalf", Number(12), "nl"), ("twintig", Number(20), "nl"), ("vijfentwintig", Number(25), "nl"),
    ("mijn tijd", LocalZone, "nl"), ("onze tijd", LocalZone, "nl"), ("hier", LocalZone, "nl"), ("bij mij", Stop, "nl"), ("bij ons", Stop, "nl"),
    ("dus", Connector, "nl"), ("oftewel", Connector, "nl"), ("of", Connector, "nl"), ("dat wil zeggen", Connector, "nl"), ("d.w.z.", Connector, "nl"),
    // pl
    ("trwa", DurationBefore, "pl"), ("przez", DurationBefore, "pl"), ("potrwa", DurationBefore, "pl"), ("około", ClockBefore, "pl"), ("ok.", ClockBefore, "pl"),
    ("do końca dnia", Idiom("eod"), "pl"), ("do końca dnia pracy", Idiom("eod"), "pl"), ("na koniec dnia", Idiom("eod"), "pl"),
    ("do południa", Idiom("noon"), "pl"), ("do północy", Idiom("midnight"), "pl"),
    ("kwadrans po", ClockShift(15), "pl"), ("za kwadrans", ClockShift(-15), "pl"), ("wpół do", HalfBefore, "pl"), ("po", Past, "pl"), ("za", ToHour, "pl"),
    ("pierwszej", Number(1), "pl"), ("drugiej", Number(2), "pl"), ("trzeciej", Number(3), "pl"), ("czwartej", Number(4), "pl"), ("piątej", Number(5), "pl"),
    ("szóstej", Number(6), "pl"), ("siódmej", Number(7), "pl"), ("ósmej", Number(8), "pl"), ("dziewiątej", Number(9), "pl"), ("dziesiątej", Number(10), "pl"),
    ("jedenastej", Number(11), "pl"), ("dwunastej", Number(12), "pl"),
    ("pierwsza", Number(1), "pl"), ("druga", Number(2), "pl"), ("trzecia", Number(3), "pl"), ("czwarta", Number(4), "pl"), ("piąta", Number(5), "pl"),
    ("szósta", Number(6), "pl"), ("siódma", Number(7), "pl"), ("ósma", Number(8), "pl"), ("dziewiąta", Number(9), "pl"), ("dziesiąta", Number(10), "pl"),
    ("jedenasta", Number(11), "pl"), ("dwunasta", Number(12), "pl"),
    ("pięć", Number(5), "pl"), ("dziesięć", Number(10), "pl"), ("dwadzieścia", Number(20), "pl"), ("dwadzieścia pięć", Number(25), "pl"),
    ("mojego czasu", LocalZone, "pl"), ("naszego czasu", LocalZone, "pl"), ("u mnie", LocalZone, "pl"), ("u nas", LocalZone, "pl"),
    ("czyli", Connector, "pl"), ("tj.", Connector, "pl"), ("tj", Connector, "pl"), ("lub", Connector, "pl"), ("albo", Connector, "pl"), ("to jest", Connector, "pl"),
    // ru
    ("с", ClockHourBefore, "ru"), ("до", ClockHourBefore, "ru"), ("в", ClockHourBefore, "ru"), ("к", ClockHourBefore, "ru"),
    ("около", ClockHourBefore, "ru"), ("после", ClockHourBefore, "ru"), ("от", ClockHourBefore, "ru"),
    ("в течение", DurationBefore, "ru"), ("длится", DurationBefore, "ru"), ("продолжительность", DurationBefore, "ru"), ("продлится", DurationBefore, "ru"),
    ("до конца рабочего дня", Idiom("eod"), "ru"), ("до конца дня", Idiom("eod"), "ru"), ("к концу дня", Idiom("eod"), "ru"),
    ("до полудня", Idiom("noon"), "ru"), ("до полуночи", Idiom("midnight"), "ru"),
    ("четверть", ClockShift(15), "ru"), ("половина", ClockShift(30), "ru"), ("без четверти", BeforeMinutes(15), "ru"), ("без", Minus, "ru"),
    ("два", Number(2), "ru"), ("две", Number(2), "ru"), ("три", Number(3), "ru"), ("четыре", Number(4), "ru"), ("пять", Number(5), "ru"),
    ("шесть", Number(6), "ru"), ("семь", Number(7), "ru"), ("восемь", Number(8), "ru"), ("девять", Number(9), "ru"), ("десять", Number(10), "ru"),
    ("одиннадцать", Number(11), "ru"), ("двенадцать", Number(12), "ru"), ("пяти", Number(5), "ru"), ("десяти", Number(10), "ru"),
    ("двадцати", Number(20), "ru"), ("двадцать", Number(20), "ru"), ("двадцати пяти", Number(25), "ru"),
    ("первого", HourOrdinal(1), "ru"), ("второго", HourOrdinal(2), "ru"), ("третьего", HourOrdinal(3), "ru"), ("четвёртого", HourOrdinal(4), "ru"),
    ("четвертого", HourOrdinal(4), "ru"), ("пятого", HourOrdinal(5), "ru"), ("шестого", HourOrdinal(6), "ru"), ("седьмого", HourOrdinal(7), "ru"),
    ("восьмого", HourOrdinal(8), "ru"), ("девятого", HourOrdinal(9), "ru"), ("десятого", HourOrdinal(10), "ru"), ("одиннадцатого", HourOrdinal(11), "ru"),
    ("двенадцатого", HourOrdinal(12), "ru"),
    ("полпервого", FixedClock(12, 30), "ru"), ("полвторого", FixedClock(1, 30), "ru"), ("полтретьего", FixedClock(2, 30), "ru"),
    ("полчетвёртого", FixedClock(3, 30), "ru"), ("полчетвертого", FixedClock(3, 30), "ru"), ("полпятого", FixedClock(4, 30), "ru"),
    ("полшестого", FixedClock(5, 30), "ru"), ("полседьмого", FixedClock(6, 30), "ru"), ("полвосьмого", FixedClock(7, 30), "ru"),
    ("полдевятого", FixedClock(8, 30), "ru"), ("полдесятого", FixedClock(9, 30), "ru"), ("полодиннадцатого", FixedClock(10, 30), "ru"),
    ("полдвенадцатого", FixedClock(11, 30), "ru"),
    ("по моему времени", LocalZone, "ru"), ("по нашему времени", LocalZone, "ru"), ("моё время", LocalZone, "ru"), ("у меня", Stop, "ru"), ("у нас", Stop, "ru"),
    ("метка времени", UnixCue, "ru"),
    ("т. е.", Connector, "ru"), ("т.е.", Connector, "ru"), ("то есть", Connector, "ru"), ("или", Connector, "ru"), ("иначе говоря", Connector, "ru"),
    // tr
    ("sürecek", DurationAfter, "tr"), ("sürer", DurationAfter, "tr"), ("boyunca", DurationAfter, "tr"), ("süreyle", DurationAfter, "tr"),
    ("civarı", Stop, "tr"), ("civarında", Stop, "tr"), ("gibi", Stop, "tr"),
    ("mesai bitimine kadar", Idiom("eod"), "tr"), ("gün sonuna kadar", Idiom("eod"), "tr"), ("mesai bitimi", Idiom("eod"), "tr"),
    ("öğlene kadar", Idiom("noon"), "tr"), ("gece yarısına kadar", Idiom("midnight"), "tr"),
    ("çeyrek geçe", ClockShift(15), "tr"), ("çeyrek kala", ClockShift(-15), "tr"), ("geçe", Past, "tr"), ("kala", ToHour, "tr"),
    ("bir", Number(1), "tr"), ("iki", Number(2), "tr"), ("üç", Number(3), "tr"), ("dört", Number(4), "tr"), ("beş", Number(5), "tr"),
    ("altı", Number(6), "tr"), ("yedi", Number(7), "tr"), ("sekiz", Number(8), "tr"), ("dokuz", Number(9), "tr"), ("on", Number(10), "tr"),
    ("on bir", Number(11), "tr"), ("on iki", Number(12), "tr"), ("yirmi", Number(20), "tr"), ("yirmi beş", Number(25), "tr"),
    ("biri", TrAcc(1), "tr"), ("ikiyi", TrAcc(2), "tr"), ("üçü", TrAcc(3), "tr"), ("dördü", TrAcc(4), "tr"), ("beşi", TrAcc(5), "tr"),
    ("altıyı", TrAcc(6), "tr"), ("yediyi", TrAcc(7), "tr"), ("sekizi", TrAcc(8), "tr"), ("dokuzu", TrAcc(9), "tr"), ("onu", TrAcc(10), "tr"),
    ("on biri", TrAcc(11), "tr"), ("on ikiyi", TrAcc(12), "tr"),
    ("bire", TrDat(1), "tr"), ("ikiye", TrDat(2), "tr"), ("üçe", TrDat(3), "tr"), ("dörde", TrDat(4), "tr"), ("beşe", TrDat(5), "tr"),
    ("altıya", TrDat(6), "tr"), ("yediye", TrDat(7), "tr"), ("sekize", TrDat(8), "tr"), ("dokuza", TrDat(9), "tr"), ("ona", TrDat(10), "tr"),
    ("on bire", TrDat(11), "tr"), ("on ikiye", TrDat(12), "tr"),
    ("bana göre", LocalZone, "tr"), ("bize göre", LocalZone, "tr"), ("benim saatimle", LocalZone, "tr"), ("benim saatimde", LocalZone, "tr"), ("bizim saatimizle", LocalZone, "tr"),
    ("zaman damgası", UnixCue, "tr"),
    ("yani", Connector, "tr"), ("veya", Connector, "tr"), ("ya da", Connector, "tr"), ("başka bir deyişle", Connector, "tr"),
    // vi
    ("kéo dài", DurationBefore, "vi"), ("trong", DurationBefore, "vi"), ("khoảng", ClockBefore, "vi"), ("tầm", ClockBefore, "vi"),
    ("trước giờ tan làm", Idiom("eod"), "vi"), ("cuối ngày làm việc", Idiom("eod"), "vi"), ("trước khi hết giờ làm", Idiom("eod"), "vi"),
    ("trước trưa", Idiom("noon"), "vi"), ("trước giờ trưa", Idiom("noon"), "vi"), ("trước nửa đêm", Idiom("midnight"), "vi"),
    ("một", Number(1), "vi"), ("hai", Number(2), "vi"), ("ba", Number(3), "vi"), ("bốn", Number(4), "vi"), ("năm", Number(5), "vi"),
    ("sáu", Number(6), "vi"), ("bảy", Number(7), "vi"), ("tám", Number(8), "vi"), ("chín", Number(9), "vi"), ("mười", Number(10), "vi"),
    ("mười một", Number(11), "vi"), ("mười hai", Number(12), "vi"),
    ("giờ của tôi", LocalZone, "vi"), ("ở đây", LocalZone, "vi"), ("giờ bên tôi", LocalZone, "vi"), ("giờ chỗ tôi", LocalZone, "vi"), ("giờ bên mình", LocalZone, "vi"),
    ("czas w", ZoneBefore, "pl"),
    ("время в", ZoneBefore, "ru"),
    ("tức là", Connector, "vi"), ("hay", Connector, "vi"), ("hoặc", Connector, "vi"), ("nghĩa là", Connector, "vi"),
    // id
    ("selama", DurationBefore, "id"), ("berlangsung", DurationBefore, "id"), ("sekitar", ClockBefore, "id"), ("kira-kira", ClockBefore, "id"),
    ("sebelum jam pulang kerja", Idiom("eod"), "id"), ("sebelum jam pulang", Idiom("eod"), "id"), ("akhir hari kerja", Idiom("eod"), "id"),
    ("sebelum tutup kantor", Idiom("eod"), "id"), ("sebelum tengah hari", Idiom("noon"), "id"), ("sebelum siang", Idiom("noon"), "id"),
    ("sebelum tengah malam", Idiom("midnight"), "id"),
    ("setengah", HalfBefore, "id"),
    ("satu", Number(1), "id"), ("dua", Number(2), "id"), ("tiga", Number(3), "id"), ("empat", Number(4), "id"), ("lima", Number(5), "id"),
    ("enam", Number(6), "id"), ("tujuh", Number(7), "id"), ("delapan", Number(8), "id"), ("sembilan", Number(9), "id"), ("sepuluh", Number(10), "id"),
    ("sebelas", Number(11), "id"), ("dua belas", Number(12), "id"), ("dua puluh", Number(20), "id"),
    ("waktu saya", LocalZone, "id"), ("waktu kita", LocalZone, "id"), ("waktu kami", LocalZone, "id"), ("di sini", LocalZone, "id"),
    ("yaitu", Connector, "id"), ("atau", Connector, "id"), ("yakni", Connector, "id"), ("alias", Connector, "id"),
    ("next week", NextAfter, "en"), ("of next week", NextAfter, "en"),
    // 箭头：目标在后（「9am ET → London」）；语言码留空，不参与投票。
    ("→", TargetTo, ""), ("->", TargetTo, ""), ("=>", TargetTo, ""), ("⇒", TargetTo, ""),
    // 土耳其语位置格的钟点数词（saat üçte = 三点）。
    ("birde", Number(1), "tr"), ("ikide", Number(2), "tr"), ("üçte", Number(3), "tr"), ("dörtte", Number(4), "tr"), ("beşte", Number(5), "tr"),
    ("altıda", Number(6), "tr"), ("yedide", Number(7), "tr"), ("sekizde", Number(8), "tr"), ("dokuzda", Number(9), "tr"), ("onda", Number(10), "tr"),
    ("on birde", Number(11), "tr"), ("on ikide", Number(12), "tr"),
    ("половине", ClockShift(30), "ru"), ("пол", ClockShift(30), "ru"),
    // 钟点的封闭变体：正午说明、带格的半点、分钟数词与连接词。
    ("open", From, "en"),
    ("am mittag", Noon, "de"), ("del mediodía", Noon, "es"), ("полуночи", Midnight, "ru"),
    ("et demi", HalfAfter, "fr"), ("l'après-midi", Period(Afternoon), "fr"),
    ("buçukta", HalfAfter, "tr"), ("thirty", Number(30), "en"),
    ("십오", Number(15), "ko"), ("piętnaście", Number(15), "pl"),
    ("all'una", FixedClock(1, 0), "it"), ("all'", RangeSep, "it"),
    ("낮", Period(Midday), "ko"), ("lúc trưa", Noon, "vi"),
    ("middaguur", Noon, "nl"), ("het middaguur", Noon, "nl"),
    // ─────────────── 「我在哪儿」的说法。日、韩、土的 cue 在地名后面（東京にいます、서울에 있어요、
    // İstanbul'dayım：土语的 cue 是带撇号的后缀，认法见装配层），其余在地名前面。法语带撇号的 cue 排版用的
    // 弯撇号折叠后同一条。cue 后面（日韩土前面）查不到地名的（I'm in a meeting、ich bin in Eile）不算说法。
    ("i'm in", SelfLocation, "en"), ("i am in", SelfLocation, "en"), ("i'm based in", SelfLocation, "en"),
    ("i am based in", SelfLocation, "en"), ("based in", SelfLocation, "en"), ("here in", SelfLocation, "en"),
    ("i'm currently in", SelfLocation, "en"), ("i live in", SelfLocation, "en"),
    ("我在", SelfLocation, "zh"), ("我人在", SelfLocation, "zh"), ("我目前在", SelfLocation, "zh"),
    ("我现在在", SelfLocation, "zh"), ("我現在在", SelfLocation, "zh"), ("我住在", SelfLocation, "zh"),
    ("にいます", SelfLocation, "ja"), ("におります", SelfLocation, "ja"), ("に住んでいます", SelfLocation, "ja"), ("在住", SelfLocation, "ja"),
    ("에 있어요", SelfLocation, "ko"), ("에 있습니다", SelfLocation, "ko"), ("에 살고 있어요", SelfLocation, "ko"), ("에 살아요", SelfLocation, "ko"),
    ("ich bin in", SelfLocation, "de"), ("ich sitze in", SelfLocation, "de"), ("ich wohne in", SelfLocation, "de"),
    ("bin gerade in", SelfLocation, "de"),
    ("estoy en", SelfLocation, "es"), ("vivo en", SelfLocation, "es"), ("me encuentro en", SelfLocation, "es"),
    ("je suis à", SelfLocation, "fr"), ("je suis en", SelfLocation, "fr"), ("je vis à", SelfLocation, "fr"),
    ("j'habite à", SelfLocation, "fr"),
    ("sono a", SelfLocation, "it"), ("sono in", SelfLocation, "it"), ("vivo a", SelfLocation, "it"), ("mi trovo a", SelfLocation, "it"),
    ("ik zit in", SelfLocation, "nl"), ("ik ben in", SelfLocation, "nl"), ("ik woon in", SelfLocation, "nl"),
    ("jestem w", SelfLocation, "pl"), ("mieszkam w", SelfLocation, "pl"),
    ("estou em", SelfLocation, "pt"), ("moro em", SelfLocation, "pt"),
    ("я в", SelfLocation, "ru"), ("я сейчас в", SelfLocation, "ru"), ("я живу в", SelfLocation, "ru"), ("нахожусь в", SelfLocation, "ru"),
    ("'dayım", SelfLocation, "tr"), ("'deyim", SelfLocation, "tr"), ("'tayım", SelfLocation, "tr"), ("'teyim", SelfLocation, "tr"),
    ("'da yaşıyorum", SelfLocation, "tr"), ("'de yaşıyorum", SelfLocation, "tr"),
    ("tôi ở", SelfLocation, "vi"), ("mình ở", SelfLocation, "vi"), ("tôi đang ở", SelfLocation, "vi"),
    ("saya di", SelfLocation, "id"), ("saya berada di", SelfLocation, "id"), ("saya tinggal di", SelfLocation, "id"), ("aku di", SelfLocation, "id"),
    // 日期和下班词可以分开书写，午夜前仍表示当天结束前。
    ("feierabend", Idiom("eod"), "de"),
    ("prima di mezzanotte", Idiom("midnight"), "it"),
    ("einde van de dag", Idiom("eod"), "nl"), ("het einde van de dag", Idiom("eod"), "nl"),
    ("przed północą", Idiom("midnight"), "pl"),
    ("к концу рабочего дня", Idiom("eod"), "ru"),
    ("trước cuối ngày", Idiom("eod"), "vi"), ("trước khi tan tầm", Idiom("eod"), "vi"),
];

/// 缩写与时区：`fixed` 为 Some 表示按固定偏移（分钟）理解（PST = UTC−8，不管夏令时），`region` 是它所指地区的 IANA 时区
/// （夏令时期间写了「标准时间」缩写的，引擎把「按地区现在的钟」也列为候选：很多人全年都写 PST）。同一个缩写有几种常见
/// 含义的（IST 印度 / 以色列 / 爱尔兰），按列出的顺序作为候选，默认第一个，宿主可按用户自己的地点改排。
/// 只认原文全大写（`ET` 算、`et` 不算），`AoE` 这类混写的单列。
pub struct Abbrev {
    pub text: &'static str,
    pub options: &'static [(Option<i32>, &'static str)],
}

pub const ABBREVIATIONS: &[Abbrev] = &[
    Abbrev { text: "UTC", options: &[(Some(0), "UTC")] },
    Abbrev { text: "GMT", options: &[(Some(0), "UTC")] },
    Abbrev { text: "Z", options: &[(Some(0), "UTC")] },
    Abbrev { text: "ET", options: &[(None, "America/New_York")] },
    Abbrev { text: "EST", options: &[(Some(-300), "America/New_York")] },
    Abbrev { text: "EDT", options: &[(Some(-240), "America/New_York")] },
    Abbrev { text: "CT", options: &[(None, "America/Chicago")] },
    Abbrev { text: "CST", options: &[(Some(-360), "America/Chicago"), (Some(480), "Asia/Shanghai"), (Some(-300), "America/Havana")] },
    Abbrev { text: "CDT", options: &[(Some(-300), "America/Chicago")] },
    Abbrev { text: "MT", options: &[(None, "America/Denver")] },
    Abbrev { text: "MST", options: &[(Some(-420), "America/Denver")] },
    Abbrev { text: "MDT", options: &[(Some(-360), "America/Denver")] },
    Abbrev { text: "PT", options: &[(None, "America/Los_Angeles")] },
    Abbrev { text: "PST", options: &[(Some(-480), "America/Los_Angeles")] },
    Abbrev { text: "PDT", options: &[(Some(-420), "America/Los_Angeles")] },
    Abbrev { text: "AKST", options: &[(Some(-540), "America/Anchorage")] },
    Abbrev { text: "AKDT", options: &[(Some(-480), "America/Anchorage")] },
    Abbrev { text: "HST", options: &[(Some(-600), "Pacific/Honolulu")] },
    Abbrev { text: "AST", options: &[(Some(-240), "America/Halifax"), (Some(180), "Asia/Riyadh")] },
    Abbrev { text: "ADT", options: &[(Some(-180), "America/Halifax")] },
    Abbrev { text: "NST", options: &[(Some(-210), "America/St_Johns")] },
    Abbrev { text: "NDT", options: &[(Some(-150), "America/St_Johns")] },
    Abbrev { text: "WET", options: &[(Some(0), "Europe/Lisbon")] },
    Abbrev { text: "WEST", options: &[(Some(60), "Europe/Lisbon")] },
    Abbrev { text: "BST", options: &[(Some(60), "Europe/London"), (Some(360), "Asia/Dhaka")] },
    Abbrev { text: "IST", options: &[(Some(330), "Asia/Kolkata"), (Some(120), "Asia/Jerusalem"), (Some(60), "Europe/Dublin")] },
    // 以色列夏令时（IST 那一条的夏天）；爱尔兰夏天写 IST，不写 IDT。
    Abbrev { text: "IDT", options: &[(Some(180), "Asia/Jerusalem")] },
    Abbrev { text: "CET", options: &[(Some(60), "Europe/Berlin")] },
    Abbrev { text: "CEST", options: &[(Some(120), "Europe/Berlin")] },
    Abbrev { text: "MEZ", options: &[(Some(60), "Europe/Berlin")] },
    Abbrev { text: "MESZ", options: &[(Some(120), "Europe/Berlin")] },
    Abbrev { text: "EET", options: &[(Some(120), "Europe/Athens")] },
    Abbrev { text: "EEST", options: &[(Some(180), "Europe/Athens")] },
    Abbrev { text: "MSK", options: &[(Some(180), "Europe/Moscow")] },
    Abbrev { text: "TRT", options: &[(Some(180), "Europe/Istanbul")] },
    Abbrev { text: "GST", options: &[(Some(240), "Asia/Dubai")] },
    Abbrev { text: "PKT", options: &[(Some(300), "Asia/Karachi")] },
    Abbrev { text: "NPT", options: &[(Some(345), "Asia/Kathmandu")] },
    Abbrev { text: "ICT", options: &[(Some(420), "Asia/Bangkok")] },
    Abbrev { text: "WIB", options: &[(Some(420), "Asia/Jakarta")] },
    Abbrev { text: "WITA", options: &[(Some(480), "Asia/Makassar")] },
    Abbrev { text: "WIT", options: &[(Some(540), "Asia/Jayapura")] },
    Abbrev { text: "SGT", options: &[(Some(480), "Asia/Singapore")] },
    Abbrev { text: "HKT", options: &[(Some(480), "Asia/Hong_Kong")] },
    Abbrev { text: "PHT", options: &[(Some(480), "Asia/Manila")] },
    Abbrev { text: "AWST", options: &[(Some(480), "Australia/Perth")] },
    Abbrev { text: "JST", options: &[(Some(540), "Asia/Tokyo")] },
    Abbrev { text: "KST", options: &[(Some(540), "Asia/Seoul")] },
    Abbrev { text: "ACST", options: &[(Some(570), "Australia/Adelaide")] },
    Abbrev { text: "ACDT", options: &[(Some(630), "Australia/Adelaide")] },
    Abbrev { text: "AEST", options: &[(Some(600), "Australia/Sydney")] },
    Abbrev { text: "AEDT", options: &[(Some(660), "Australia/Sydney")] },
    Abbrev { text: "NZST", options: &[(Some(720), "Pacific/Auckland")] },
    Abbrev { text: "NZDT", options: &[(Some(780), "Pacific/Auckland")] },
    Abbrev { text: "BRT", options: &[(Some(-180), "America/Sao_Paulo")] },
    Abbrev { text: "ART", options: &[(Some(-180), "America/Argentina/Buenos_Aires")] },
    Abbrev { text: "CLT", options: &[(Some(-240), "America/Santiago")] },
    Abbrev { text: "COT", options: &[(Some(-300), "America/Bogota")] },
    Abbrev { text: "PET", options: &[(Some(-300), "America/Lima")] },
    Abbrev { text: "SAST", options: &[(Some(120), "Africa/Johannesburg")] },
    Abbrev { text: "WAT", options: &[(Some(60), "Africa/Lagos")] },
    Abbrev { text: "CAT", options: &[(Some(120), "Africa/Maputo")] },
    Abbrev { text: "EAT", options: &[(Some(180), "Africa/Nairobi")] },
    Abbrev { text: "AOE", options: &[(Some(-720), "Etc/GMT+12")] },
    Abbrev { text: "МСК", options: &[(Some(180), "Europe/Moscow")] },
];

/// 时区词封闭表：每种语言都有「国家标准时间」锚点词与美国区域词，用户拿它当参照而不是城市名。
/// 只收有唯一答案的词；「澳洲时间」这类一国多区的不收。区域词映射到 IANA 时区（随夏令时），缩写在 `zone` 里按固定偏移。
/// 引擎的 `units.rs` 与 `EXTRA_ZONE_WORDS` 共用这张表。
#[cfg(test)]
pub(crate) const ZONE_WORDS: &[(&str, &str)] = &[
    // zh-Hans / zh-Hant
    ("北京时间", "Asia/Shanghai"), ("北京時間", "Asia/Shanghai"), ("中国时间", "Asia/Shanghai"), ("中國時間", "Asia/Shanghai"),
    ("东八区", "Asia/Shanghai"), ("東八區", "Asia/Shanghai"),
    ("美东时间", "America/New_York"), ("美東時間", "America/New_York"), ("美东", "America/New_York"), ("美東", "America/New_York"),
    ("东部时间", "America/New_York"), ("東部時間", "America/New_York"),
    ("美西时间", "America/Los_Angeles"), ("美西時間", "America/Los_Angeles"), ("美西", "America/Los_Angeles"),
    ("太平洋时间", "America/Los_Angeles"), ("太平洋時間", "America/Los_Angeles"),
    ("美中时间", "America/Chicago"), ("美中時間", "America/Chicago"), ("美中", "America/Chicago"),
    ("中部时间", "America/Chicago"), ("中部時間", "America/Chicago"), ("中央时间", "America/Chicago"), ("中央時間", "America/Chicago"),
    ("山地时间", "America/Denver"), ("山地時間", "America/Denver"),
    ("欧洲中部时间", "Europe/Berlin"), ("歐洲中部時間", "Europe/Berlin"),
    ("格林尼治时间", "UTC"), ("格林威治時間", "UTC"), ("格林威治时间", "UTC"), ("世界时", "UTC"), ("世界時", "UTC"), ("协调世界时", "UTC"), ("協調世界時", "UTC"),
    ("香港时间", "Asia/Hong_Kong"), ("香港時間", "Asia/Hong_Kong"), ("台北时间", "Asia/Taipei"), ("台北時間", "Asia/Taipei"), ("台湾时间", "Asia/Taipei"), ("台灣時間", "Asia/Taipei"),
    ("新加坡时间", "Asia/Singapore"), ("新加坡時間", "Asia/Singapore"), ("日本时间", "Asia/Tokyo"), ("日本時間", "Asia/Tokyo"), ("东京时间", "Asia/Tokyo"), ("東京時間", "Asia/Tokyo"),
    ("韩国时间", "Asia/Seoul"), ("韓國時間", "Asia/Seoul"), ("首尔时间", "Asia/Seoul"), ("首爾時間", "Asia/Seoul"),
    ("印度时间", "Asia/Kolkata"), ("印度時間", "Asia/Kolkata"), ("迪拜时间", "Asia/Dubai"), ("杜拜時間", "Asia/Dubai"),
    ("悉尼时间", "Australia/Sydney"), ("雪梨時間", "Australia/Sydney"), ("伦敦时间", "Europe/London"), ("倫敦時間", "Europe/London"), ("英国时间", "Europe/London"), ("英國時間", "Europe/London"),
    ("巴黎时间", "Europe/Paris"), ("巴黎時間", "Europe/Paris"), ("柏林时间", "Europe/Berlin"), ("柏林時間", "Europe/Berlin"), ("莫斯科时间", "Europe/Moscow"), ("莫斯科時間", "Europe/Moscow"),
    ("纽约时间", "America/New_York"), ("紐約時間", "America/New_York"), ("洛杉矶时间", "America/Los_Angeles"), ("洛杉磯時間", "America/Los_Angeles"), ("芝加哥时间", "America/Chicago"), ("芝加哥時間", "America/Chicago"),
    // en（两字母 ET / PT / CT / MT 只认全大写，在 zone 里单独处理）
    ("eastern time", "America/New_York"), ("us eastern", "America/New_York"), ("pacific time", "America/Los_Angeles"), ("us pacific", "America/Los_Angeles"),
    ("central time", "America/Chicago"), ("us central", "America/Chicago"), ("mountain time", "America/Denver"),
    ("beijing time", "Asia/Shanghai"), ("china time", "Asia/Shanghai"), ("china standard time", "Asia/Shanghai"), ("hong kong time", "Asia/Hong_Kong"), ("taipei time", "Asia/Taipei"), ("taiwan time", "Asia/Taipei"),
    ("singapore time", "Asia/Singapore"), ("japan time", "Asia/Tokyo"), ("tokyo time", "Asia/Tokyo"), ("korea time", "Asia/Seoul"), ("korean time", "Asia/Seoul"), ("seoul time", "Asia/Seoul"),
    ("india time", "Asia/Kolkata"), ("indian time", "Asia/Kolkata"), ("philippine time", "Asia/Manila"), ("manila time", "Asia/Manila"), ("dubai time", "Asia/Dubai"),
    ("london time", "Europe/London"), ("uk time", "Europe/London"), ("british time", "Europe/London"), ("paris time", "Europe/Paris"), ("berlin time", "Europe/Berlin"), ("moscow time", "Europe/Moscow"),
    ("sydney time", "Australia/Sydney"), ("new york time", "America/New_York"), ("los angeles time", "America/Los_Angeles"), ("chicago time", "America/Chicago"), ("brasilia time", "America/Sao_Paulo"),
    ("anywhere on earth", "Etc/GMT+12"), ("aoe", "Etc/GMT+12"), ("zulu", "UTC"), ("zulu time", "UTC"),
    // ja
    ("日本時間", "Asia/Tokyo"), ("東部時間", "America/New_York"), ("米東部時間", "America/New_York"), ("アメリカ東部時間", "America/New_York"),
    ("太平洋時間", "America/Los_Angeles"), ("米太平洋時間", "America/Los_Angeles"), ("中部時間", "America/Chicago"), ("山岳部時間", "America/Denver"),
    ("英国時間", "Europe/London"), ("イギリス時間", "Europe/London"), ("中国時間", "Asia/Shanghai"), ("韓国時間", "Asia/Seoul"), ("協定世界時", "UTC"), ("グリニッジ標準時", "UTC"),
    ("ニューヨーク時間", "America/New_York"), ("ロンドン時間", "Europe/London"), ("パリ時間", "Europe/Paris"),
    // ko
    ("한국시간", "Asia/Seoul"), ("한국 시간", "Asia/Seoul"), ("서울시간", "Asia/Seoul"), ("동부시간", "America/New_York"), ("미국 동부시간", "America/New_York"), ("미국동부시간", "America/New_York"), ("미국 동부 시간", "America/New_York"),
    ("서부시간", "America/Los_Angeles"), ("미국 서부시간", "America/Los_Angeles"), ("미국서부시간", "America/Los_Angeles"), ("태평양시간", "America/Los_Angeles"), ("태평양 시간", "America/Los_Angeles"),
    ("중부시간", "America/Chicago"), ("일본시간", "Asia/Tokyo"), ("일본 시간", "Asia/Tokyo"), ("중국시간", "Asia/Shanghai"), ("중국 시간", "Asia/Shanghai"), ("영국시간", "Europe/London"), ("영국 시간", "Europe/London"), ("협정세계시", "UTC"),
    // de
    ("ostküstenzeit", "America/New_York"), ("ostküste", "America/New_York"), ("westküstenzeit", "America/Los_Angeles"), ("westküste", "America/Los_Angeles"),
    ("deutsche zeit", "Europe/Berlin"), ("deutscher zeit", "Europe/Berlin"), ("londoner zeit", "Europe/London"), ("moskauer zeit", "Europe/Moscow"), ("pekinger zeit", "Asia/Shanghai"), ("chinesische zeit", "Asia/Shanghai"), ("chinesischer zeit", "Asia/Shanghai"), ("japanische zeit", "Asia/Tokyo"), ("japanischer zeit", "Asia/Tokyo"), ("new yorker zeit", "America/New_York"),
    ("weltzeit", "UTC"),
    // fr
    ("heure de l'est", "America/New_York"), ("heure de l’est", "America/New_York"), ("heure de l'est américaine", "America/New_York"), ("heure du pacifique", "America/Los_Angeles"), ("heure du centre", "America/Chicago"), ("heure des rocheuses", "America/Denver"),
    ("heure de paris", "Europe/Paris"), ("heure de new york", "America/New_York"), ("heure de londres", "Europe/London"), ("heure de tokyo", "Asia/Tokyo"), ("heure de pékin", "Asia/Shanghai"), ("heure de pekin", "Asia/Shanghai"), ("heure de moscou", "Europe/Moscow"), ("heure de montréal", "America/Toronto"), ("heure de montreal", "America/Toronto"),
    ("temps universel", "UTC"), ("temps universel coordonné", "UTC"),
    // es
    ("hora del este", "America/New_York"), ("hora del pacífico", "America/Los_Angeles"), ("hora del pacifico", "America/Los_Angeles"), ("hora central", "America/Chicago"), ("hora de la montaña", "America/Denver"), ("hora de la montana", "America/Denver"),
    ("hora de nueva york", "America/New_York"), ("hora de madrid", "Europe/Madrid"), ("hora de españa", "Europe/Madrid"), ("hora de espana", "Europe/Madrid"), ("hora españa", "Europe/Madrid"), ("hora espana", "Europe/Madrid"), ("hora de méxico", "America/Mexico_City"), ("hora de mexico", "America/Mexico_City"), ("hora de ciudad de méxico", "America/Mexico_City"),
    ("hora de bogotá", "America/Bogota"), ("hora de bogota", "America/Bogota"), ("hora de colombia", "America/Bogota"), ("hora de buenos aires", "America/Argentina/Buenos_Aires"), ("hora de argentina", "America/Argentina/Buenos_Aires"), ("hora de chile", "America/Santiago"), ("hora de lima", "America/Lima"), ("hora de perú", "America/Lima"), ("hora de peru", "America/Lima"),
    ("hora de londres", "Europe/London"), ("hora de pekín", "Asia/Shanghai"), ("hora de pekin", "Asia/Shanghai"), ("hora de tokio", "Asia/Tokyo"), ("hora universal", "UTC"),
    // pt
    ("horário de brasília", "America/Sao_Paulo"), ("horario de brasilia", "America/Sao_Paulo"), ("hora de brasília", "America/Sao_Paulo"), ("hora de brasilia", "America/Sao_Paulo"),
    ("horário de nova york", "America/New_York"), ("horario de nova york", "America/New_York"), ("horário de nova iorque", "America/New_York"), ("horário de lisboa", "Europe/Lisbon"), ("horario de lisboa", "Europe/Lisbon"), ("hora de lisboa", "Europe/Lisbon"),
    ("horário do leste", "America/New_York"), ("horario do leste", "America/New_York"), ("horário do pacífico", "America/Los_Angeles"), ("horario do pacifico", "America/Los_Angeles"), ("horário central", "America/Chicago"), ("horario central", "America/Chicago"),
    ("horário de londres", "Europe/London"), ("horario de londres", "Europe/London"), ("horário de tóquio", "Asia/Tokyo"), ("horario de toquio", "Asia/Tokyo"), ("horário de pequim", "Asia/Shanghai"), ("horario de pequim", "Asia/Shanghai"), ("tempo universal", "UTC"),
    // ru
    ("по москве", "Europe/Moscow"), ("московское время", "Europe/Moscow"), ("по московскому времени", "Europe/Moscow"),
    ("восточное время сша", "America/New_York"), ("восточное время", "America/New_York"), ("тихоокеанское время", "America/Los_Angeles"), ("центральное время", "America/Chicago"), ("горное время", "America/Denver"),
    ("по владивостоку", "Asia/Vladivostok"), ("по киеву", "Europe/Kyiv"), ("по лондону", "Europe/London"), ("по пекину", "Asia/Shanghai"), ("по токио", "Asia/Tokyo"), ("по нью-йорку", "America/New_York"), ("всемирное время", "UTC"),
];

// 问题只引用不成立的内容，介词和带出的冠词不属于问题文字。
pub(super) const ISSUE_PREFIXES: &[&str] = &[
    "at", "by", "before", "on", "in the", "in", // en
    "um", "bis", "am", "im", "vor", // de
    "a las", "de la", "por la", "de", "a", // es
    "à", "du", "avant", "dans la", "dans", "au", // fr
    "alle", "all'", "prima di", "di", // it
    "vóór het", "voor het", "vóór", "voor", "om", "tot", // nl
    "przed", "do", "o", "we", "w", // pl
    "перед", "до", "к", "во", "в", "по", // ru
    "trước khi", "trước", "vào", "lúc", // vi
    "às", "antes de", "em", // pt
    "saat", // tr
    "pukul", "sebelum", // id
];
pub(super) const ISSUE_SUFFIXES: &[&str] = &[
    "之前", "前", "まで", "までに", "전에", "전", "까지", "kadar", "önce",
];

/// 日末短语围着写明的日子匹配；空串表示那一侧不需要词。
pub(super) const DAY_END_CUES: &[(&str, &str, &str)] = &[
    ("until the end of", "", "en"), ("by the end of", "", "en"), ("before the end of", "", "en"),
    ("", "until the end of the day", "en"), ("", "by the end of the day", "en"),
    ("bis zum Ende des", "", "de"), ("bis zum Ende von", "", "de"), ("bis Ende", "", "de"),
    ("hasta el final del", "", "es"), ("hasta el final de", "", "es"), ("hasta el fin del", "", "es"),
    ("jusqu'à la fin de", "", "fr"), ("jusqu'à la fin du", "", "fr"), ("avant la fin de", "", "fr"),
    ("fino alla fine di", "", "it"), ("entro la fine di", "", "it"),
    ("", "の終わりまで", "ja"), ("", "が終わるまで", "ja"), ("", "の終わりまでに", "ja"),
    ("", "끝까지", "ko"), ("", "말까지", "ko"), ("", "하루가 끝날 때까지", "ko"),
    ("tot het einde van", "", "nl"), ("voor het einde van", "", "nl"),
    ("do końca", "", "pl"), ("", "do końca dnia", "pl"),
    ("до конца", "", "ru"), ("", "до конца дня", "ru"),
    ("", "gün sonuna kadar", "tr"), ("", "sonuna kadar", "tr"),
    ("đến hết", "", "vi"), ("cho đến hết", "", "vi"), ("đến hết ngày", "", "vi"), ("cho đến hết ngày", "", "vi"),
    ("sampai akhir hari", "", "id"), ("hingga akhir hari", "", "id"),
    ("sampai akhir", "", "id"), ("hingga akhir", "", "id"),
    ("até o fim de", "", "pt-BR"), ("até o final de", "", "pt-BR"),
    ("直到", "结束", "zh-Hans"), ("到", "结束为止", "zh-Hans"), ("", "结束前", "zh-Hans"),
    ("直到", "結束", "zh-Hant"), ("到", "結束為止", "zh-Hant"), ("", "結束前", "zh-Hant"),
];

// 日期连接词的折叠单元；只用于后置日期归属，不把活动用语当连接词。
pub(super) const DATE_LINK_WORDS: &[&[&str]] = &[
    &["on"], &["the"], &["of"], // en
    &["于"], &["於"], &["在"], &["的"], // zh-Hans / zh-Hant
    &["に"], &["の"], // ja
    &["에"], // ko
    &["am"], &["an"], &["der"], &["den"], &["des"], // de
    &["le"], &["du"], &["de"], &["la"], // fr
    &["el"], &["del"], // es
    &["в"], &["во"], &["на"], // ru
    &["no"], &["na"], &["do"], &["da"], &["dia"], &["em"], // pt-BR
    &["il"], &["lo"], &["di"], // it
    &["op"], &["het"], &["van"], // nl
    &["w"], &["we"], &["dnia"], // pl
    &["da"], &["de"], &["'", "da"], &["'", "de"], // tr
    &["vao"], &["ngay"], // vi
    &["pada"], &["tanggal"], &["hari"], // id
];

// 仅供前置附近地点使用，不进入原有相邻地点、日期或钟点词法。
// 补齐主语、常见动作与叹词，折叠后按本分句语言查封闭表。
pub(super) fn nearby_common_word(word: &str, language: &str) -> bool {
    use std::{collections::HashMap, sync::OnceLock};
    static WORDS: OnceLock<HashMap<String, Vec<&'static str>>> = OnceLock::new();
    let words = WORDS.get_or_init(|| {
        let mut words: HashMap<String, Vec<&'static str>> = HashMap::new();
        for (language, list) in [
            ("en", "i we you they he she it arrive arrives arriving come comes meet meets nice well yes no hello oh a an the at in on to from of with by for is are am was were be been being there exists"),
            ("zh", "我 我们 我們 你 你们 你們 他 她 他们 他們 她们 她們 到 到达 到達 见面 見面 啊 嗯 哦 的 地 得 在 到 从 從 向 给 給 和 与 與 是 有 为 為 了 这 這 那 此 于 於"),
            ("ja", "私 私たち 僕 僕ら あなた 彼 彼女 到着 会う はい いいえ ああ は が を に へ で と の も から まで です だ ある あります いる います"),
            ("ko", "나 저 우리 우리는 저는 너 그 그녀 도착 만나요 네 아니요 아 은 는 이 가 을 를 에 에서 의 로 으로 와 과 있다 있습니다 입니다 이다"),
            ("de", "ich wir du ihr sie er es komme kommen kommt treffen ja nein hallo oh der die das ein eine einer einem einen des dem den im am zum zur ins vom von zu mit für bei ist sind bin war waren es gibt"),
            ("fr", "je nous tu vous ils elles il elle viens vient venons arrive arrivent oui non salut oh le la les un une des de du au aux à en dans sur pour par avec est sont suis était il y a l d"),
            ("es", "yo nosotros nosotras tú ustedes ellos ellas él ella llego llega llegamos vemos sí no hola ay el la los las un una unos unas al del de en a con por para es son soy hay está están"),
            ("ru", "я мы ты вы он она они приду придём прихожу приходим встретимся да нет привет ах в во на к ко с со у о об от до для по из и есть это был была были"),
            ("pt", "eu nós você vocês eles elas ele ela chego chega chegamos encontro encontramos sim não olá oi o a os as ao aos à às no na nos nas do da dos das em um uma uns umas de para por com é são sou está estão há tem"),
            ("it", "io noi tu voi loro lui lei arrivo arriva arriviamo vediamo sì no ciao oh il lo la i gli le un uno una al del alla allo alle ai agli dal dalla dello della di da in su con per è sono cè"),
            ("nl", "ik wij we jij jullie zij hij het kom komen komt ontmoeten ja nee hallo oh de het een in op aan naar van voor met bij is zijn ben was waren er"),
            ("pl", "ja my ty wy on ona oni one przyjdę przychodzę spotykamy tak nie cześć och w we na do z ze od dla o u po i jest są jestem był była"),
            ("tr", "ben biz sen siz o onlar gelirim gelir geliyoruz buluşuruz evet hayır merhaba ah ve bir bu şu o ile için de da den dan var yok olmak olan olur"),
            ("vi", "tôi chúng ta mình bạn các họ anh ấy đến tới gặp nhau có không chào ôi ở tại vào đến từ của với cho là có được một những các trong trên và"),
            ("id", "saya aku kami kita kamu anda kalian dia mereka tiba datang bertemu akan baru malang bisa ya tidak halo aduh wah ada di ke ini itu jam sebuah suatu adalah ialah merupakan pada dari untuk dengan yang dan pukul"),
        ] {
            for word in list.split_whitespace() {
                words.entry(super::text::fold_str(word)).or_default().push(language);
            }
        }
        words
    });
    let language = language.split(['-', '_']).next().unwrap_or(language);
    words.get(word).is_some_and(|languages| languages.contains(&language))
}
