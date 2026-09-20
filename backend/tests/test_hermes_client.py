import unittest
from unittest.mock import patch
import urllib.error
from integrations.hermes.ark_bridge import Client, public_run, valid_id

class ClientTests(unittest.TestCase):
    def test_rejects_remote_credential_destination(self):
        for base in ('https://example.com','http://127.0.0.1.evil.test','http://user@localhost:8765'):
            with self.assertRaises(ValueError): Client(base=base)
        with self.assertRaises(ValueError): valid_id('../approvals')

    def test_unknown_submission_returns_stable_lookup_without_retry(self):
        client=Client()
        with patch.object(client,'request',side_effect=urllib.error.URLError('lost')) as request:
            result=client.call('reminders.create_reminder',{'title':'test'},'session')
        self.assertEqual(request.call_count,1)
        self.assertEqual(result['status'],'result_unknown')
        self.assertEqual(valid_id(result['run_id']),result['run_id'])

    def test_denied_submission_is_not_reported_as_accepted(self):
        client=Client()
        with patch.object(client,'request',side_effect=urllib.error.HTTPError('local',409,'disabled',{},None)):
            with self.assertRaises(urllib.error.HTTPError): client.call('reminders.create_reminder',{},'s')

    def test_accepted_request_with_lost_status_is_not_resubmitted(self):
        client=Client()
        with patch.object(client,'request',side_effect=[{'id':'a'*32},urllib.error.URLError('lost')]) as request:
            result=client.call('workspace.write_file',{},'s')
        self.assertEqual(request.call_count,2)
        self.assertEqual(result['run_id'],'a'*32)
        self.assertEqual(result['status'],'result_unknown')

    def test_public_state_does_not_expose_approval_digest(self):
        for status in ('preparing','waiting_approval','succeeded'):
            result=public_run({'id':'a'*32,'status':status,'pending':{'digest':'private'},'calls':[]})
            self.assertNotIn('pending',result)
            self.assertEqual(result['status'],status)
        self.assertIn('不等于等待审批',public_run({'id':'a'*32,'status':'preparing'})['next_action'])


class ReminderClockTests(unittest.TestCase):
    def test_relative_dates_use_calendar_arithmetic(self):
        from datetime import datetime
        from integrations.hermes.ark_bridge import reminder_clock
        for date,expected in [('2026-09-20T16:00:00+08:00','2026-09-22'),
                              ('2026-12-31T23:59:00+08:00','2027-01-02'),
                              ('2028-02-28T10:00:00+08:00','2028-03-01')]:
            self.assertIn('"后天": "'+expected+'"',reminder_clock(datetime.fromisoformat(date)))

    def test_clock_normalizes_timezone_before_selecting_date(self):
        from datetime import datetime
        from integrations.hermes.ark_bridge import reminder_clock
        self.assertIn('"今天": "2026-09-21"',reminder_clock(datetime.fromisoformat('2026-09-20T17:00:00+00:00')))
