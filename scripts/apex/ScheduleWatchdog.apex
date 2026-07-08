// Schedules the AAO watchdog hourly (idempotent). Run with:
// sf apex run --file scripts/apex/ScheduleWatchdog.apex --target-org aao
List<CronTrigger> existing = [
  SELECT Id
  FROM CronTrigger
  WHERE CronJobDetail.Name = 'AAO Watchdog'
];
if (existing.isEmpty()) {
  System.schedule('AAO Watchdog', '0 0 * * * ?', new AgentWatchdogSchedulable());
  System.debug('Watchdog scheduled hourly.');
} else {
  System.debug('Watchdog already scheduled.');
}
