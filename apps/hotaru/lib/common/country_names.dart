/// Localized country names for the codes proxy exits commonly land in.
/// A code outside the table has no name here; callers fall back to the
/// code alone rather than guessing.
const _countryNames = <String, (String, String)>{
  'JP': ('日本', 'Japan'),
  'US': ('美国', 'United States'),
  'CN': ('中国', 'China'),
  'HK': ('中国香港', 'Hong Kong'),
  'TW': ('中国台湾', 'Taiwan'),
  'MO': ('中国澳门', 'Macau'),
  'SG': ('新加坡', 'Singapore'),
  'KR': ('韩国', 'South Korea'),
  'GB': ('英国', 'United Kingdom'),
  'DE': ('德国', 'Germany'),
  'FR': ('法国', 'France'),
  'NL': ('荷兰', 'Netherlands'),
  'CH': ('瑞士', 'Switzerland'),
  'SE': ('瑞典', 'Sweden'),
  'NO': ('挪威', 'Norway'),
  'DK': ('丹麦', 'Denmark'),
  'FI': ('芬兰', 'Finland'),
  'IS': ('冰岛', 'Iceland'),
  'IE': ('爱尔兰', 'Ireland'),
  'IT': ('意大利', 'Italy'),
  'ES': ('西班牙', 'Spain'),
  'PT': ('葡萄牙', 'Portugal'),
  'AT': ('奥地利', 'Austria'),
  'BE': ('比利时', 'Belgium'),
  'PL': ('波兰', 'Poland'),
  'CZ': ('捷克', 'Czechia'),
  'HU': ('匈牙利', 'Hungary'),
  'RO': ('罗马尼亚', 'Romania'),
  'BG': ('保加利亚', 'Bulgaria'),
  'GR': ('希腊', 'Greece'),
  'UA': ('乌克兰', 'Ukraine'),
  'RU': ('俄罗斯', 'Russia'),
  'TR': ('土耳其', 'Türkiye'),
  'IL': ('以色列', 'Israel'),
  'AE': ('阿联酋', 'United Arab Emirates'),
  'SA': ('沙特阿拉伯', 'Saudi Arabia'),
  'EG': ('埃及', 'Egypt'),
  'ZA': ('南非', 'South Africa'),
  'NG': ('尼日利亚', 'Nigeria'),
  'KE': ('肯尼亚', 'Kenya'),
  'IN': ('印度', 'India'),
  'PK': ('巴基斯坦', 'Pakistan'),
  'BD': ('孟加拉国', 'Bangladesh'),
  'LK': ('斯里兰卡', 'Sri Lanka'),
  'NP': ('尼泊尔', 'Nepal'),
  'MM': ('缅甸', 'Myanmar'),
  'TH': ('泰国', 'Thailand'),
  'VN': ('越南', 'Vietnam'),
  'MY': ('马来西亚', 'Malaysia'),
  'ID': ('印度尼西亚', 'Indonesia'),
  'PH': ('菲律宾', 'Philippines'),
  'KH': ('柬埔寨', 'Cambodia'),
  'LA': ('老挝', 'Laos'),
  'AU': ('澳大利亚', 'Australia'),
  'NZ': ('新西兰', 'New Zealand'),
  'CA': ('加拿大', 'Canada'),
  'MX': ('墨西哥', 'Mexico'),
  'BR': ('巴西', 'Brazil'),
  'AR': ('阿根廷', 'Argentina'),
  'CL': ('智利', 'Chile'),
  'CO': ('哥伦比亚', 'Colombia'),
  'PE': ('秘鲁', 'Peru'),
  'VE': ('委内瑞拉', 'Venezuela'),
};

/// The name of [countryCode] in Chinese for a zh locale and in English
/// otherwise; null when the code is not in the table.
String? countryNameOf(String? countryCode, String languageCode) {
  if (countryCode == null) {
    return null;
  }
  final names = _countryNames[countryCode.toUpperCase()];
  if (names == null) {
    return null;
  }
  return languageCode == 'zh' ? names.$1 : names.$2;
}
