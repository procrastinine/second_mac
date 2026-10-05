ObjC.import('Foundation');
for (var pair of [
  ['com.apple.SubmitDiagInfo', 'AutoSubmit'],
  ['com.apple.applicationaccess', 'allowDiagnosticSubmission'],
  ['com.apple.ironwood.support', 'Assistant Allowed'],
  ['com.brave.Browser', 'MetricsReportingEnabled'],
  ['com.brave.Browser', 'BraveP3AEnabled'],
  ['com.brave.Browser', 'BraveStatsPingEnabled'],
]) {
  var prefs = $.NSUserDefaults.alloc.initWithSuiteName(pair[0]);
  if (ObjC.unwrap(prefs.objectForKey(pair[1])) !== false || !prefs.objectIsForcedForKey(pair[1])) {
    throw new Error('Privacy policy not effective: ' + pair.join(':'));
  }
}
'Privacy policies: active';
