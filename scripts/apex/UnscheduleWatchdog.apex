// Aborts the AAO watchdog cron so Apex classes can deploy (re-schedule afterwards with
// ScheduleWatchdog.apex). Scheduled Apex blocks class deployment unless the org allows
// deployments with active jobs.
for (CronTrigger job : [
  SELECT Id
  FROM CronTrigger
  WHERE CronJobDetail.Name = 'AAO Watchdog'
]) {
  System.abortJob(job.Id);
  System.debug('Aborted watchdog job ' + job.Id);
}
