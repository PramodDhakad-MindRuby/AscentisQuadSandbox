/**
* @description       : This Apex class sends an email reminder to Account owners notifying them about Accounts
*                      with Client Type = "FP Only", Segmentation__c != null, and Quad_Meeting_Creation_Pending__c = false.
*                      Each email contains clickable Account links. Uses OrgWideEmailAddress and custom labels for flexibility.
* @author            : Setul Sahu/ MindRuby
* @group             :
* @last modified on  : 05-22-2026
* @last modified by  : Setul Sahu/ MindRuby
**/
public without sharing class FPOnlyHouseholdReminderService {
    @TestVisible static Boolean bypassOrgWideLookup = false;
    @TestVisible static Boolean bypassEmailSend = false;
    @TestVisible static List<Messaging.SingleEmailMessage> capturedEmails = new List<Messaging.SingleEmailMessage>();

    @TestVisible
    public static void sendReminders(Boolean isFinalNotice) {
        
        // Get base URL for Account links
        String baseUrl = System.URL.getOrgDomainUrl().toExternalForm();
            // Dynamic Salesforce Report ID for FP Only Client report
            // Store this in a Custom Label for easy deployment/configuration
            String fpOnlyReportId = System.Label.FPONLY_CLIENT_REPORT_ID; // e.g., '00OWB0000024qtK2AQ'
            String reportUrl = baseUrl + '/lightning/r/Report/' + fpOnlyReportId + '/view';
        
        // Custom Label for OrgWideEmailAddress
        String dynamicEmail = System.Label.FPONLY_HOUSEHOLD_FROM_EMAIL;
        List<String> ccEmails = System.Label.FPONLY_HOUSEHOLD_CC != null ? System.Label.FPONLY_HOUSEHOLD_CC.split(',') : new List<String>();


        // Query OrgWideEmailAddress
        OrgWideEmailAddress orgWide;
        if (!bypassOrgWideLookup) {
            List<OrgWideEmailAddress> orgWideList = [
                SELECT Id, Address
                FROM OrgWideEmailAddress
                WHERE Address = :dynamicEmail
                LIMIT 1
            ];
            if (orgWideList.isEmpty()) {
                System.debug('No matching OrgWideEmailAddress found.');
                return;
            }
            orgWide = orgWideList[0];
        }

        // Query Accounts meeting the criteria
        List<Account> accounts = [
            SELECT Id, Name, OwnerId, Owner.Email, Owner.FirstName,Segmentation__c
            FROM Account
            WHERE Client_Type__c = 'FP Only'
              AND Segmentation__c != null
              AND Quad_Meeting_Creation_Pending__c = false
              AND Owner.Email != null
        ];

        // Group accounts by owner
        Map<Id, List<Account>> ownerToAccounts = new Map<Id, List<Account>>();
        for (Account acc : accounts) {
            if (!ownerToAccounts.containsKey(acc.OwnerId)) {
                ownerToAccounts.put(acc.OwnerId, new List<Account>());
            }
            ownerToAccounts.get(acc.OwnerId).add(acc);
        }

        // Create one email per owner
        List<Messaging.SingleEmailMessage> emailsToSend = new List<Messaging.SingleEmailMessage>();
        for (Id ownerId : ownerToAccounts.keySet()) {
            List<Account> ownerAccounts = ownerToAccounts.get(ownerId);
            Account firstAcc = ownerAccounts[0]; // Use first account to get owner details
            if (firstAcc.Owner.Email != null) {
                Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
                mail.setToAddresses(new List<String>{firstAcc.Owner.Email});
                mail.setSubject(isFinalNotice ? 'The window closes soon — Final Notice' : 'The segmentation window is open.');

                // Dynamic values
                String advisorName = (firstAcc.Owner.FirstName != null ? firstAcc.Owner.FirstName : 'Advisor');
                Integer fpOnlyCount = ownerAccounts.size();
                String year = String.valueOf(Date.today().year() + 1);
                String lockDate = '01 Jan ' + year;
                String windowClose = '31 Dec ' + String.valueOf(Date.today().year());
                String finalNotice = '15 Dec ' + String.valueOf(Date.today().year());
                Integer daysLeft = Date.newInstance(Date.today().year(), 12, 31).daysBetween(Date.today());

                // Only show up to 10 records in the email
                List<Account> ownerAccountsToShow = new List<Account>();
                for (Integer i = 0; i < 10 && i < ownerAccounts.size(); i++) {
                    ownerAccountsToShow.add(ownerAccounts[i]);
                }
                Boolean hasMoreAccounts = ownerAccounts.size() > 10;

                String emailBody;
                if (isFinalNotice) {
                    // FINAL NOTICE TEMPLATE
                    emailBody = ''
                    + '<div style="display:flex;justify-content:center;">'
                    + '<div style="min-width:900px;max-width:600px;font-family:\'Segoe UI\',Arial,sans-serif,serif,EmojiFont;background:#f8fafc;padding:0;margin:0;">'
                    + '<div style="background:#14213d;margin:0 auto 0 auto;border-radius:8px 8px 0 0;">'
                    + '<div style="height:56px;display:flex;align-items:center;justify-content:left;margin:0 auto;padding:0 0 0 0;">'
                    + '<span style="color:#fff;font-size:1.5rem;font-weight:700;letter-spacing:2px;margin-left:24px;">ASCENTIS</span>'
                    + '</div></div>'
                    + '<div style="margin:0 auto;background:#fff;border-radius:0 0 8px 8px;box-shadow:0 2px 8px #0001;padding:40px 32px 32px 32px;">'
                    + '<div style="color:#bfa243;font-size:13px;letter-spacing:1.5px;font-weight:600;margin-bottom:16px;">SEGMENTATION · FY ' + year + ' · NOTICE 02 · FINAL</div>'
                    + '<h1 style="font-size:2rem;color:#14213d;margin:0 0 16px 0;">The window closes in <i>' + daysLeft + ' days</i>.</h1>'
                    + '<div style="font-size:1.1rem;color:#14213d;margin-bottom:24px;">'
                    + 'Hi <b>' + advisorName + '</b> — your <b>' + fpOnlyCount + '</b> FP Only households lock to their ' + year + ' segment on <b>' + lockDate + '</b>. Confirm your roster now — this is the final notice.'
                    + '</div>'
                    + '<hr style="border:none;border-top:1px solid #eee;margin:24px 0;">'
                    + '<div style="color:#14213d;font-size:1rem;margin-bottom:24px;">'
                    + 'The window closes <b>' + windowClose + '</b>. Any FP Only household not updated by then carries its current segment into ' + year + ' and cannot be changed until the next window.<br><br>'
                    + 'This notice covers FP Only clients only. Wealth client segments recalculate automatically on <b>' + lockDate + '</b>. Asset and Independent Advisor clients are not affected.<br><br>'
                    + 'You must update a household’s segment when its agreement, Stated Net Worth, Stated Household Income, or Billed AUM has moved it to a different tier (AAA, A, B, C). If nothing has changed, no action is required — the current segment carries into ' + year + '.'
                    + '</div>'
                    + '<a href="' + reportUrl + '" style="display:inline-block;background:#bfa243;color:#14213d;font-weight:600;padding:12px 28px;border-radius:6px;text-decoration:none;margin-bottom:32px;margin-top:8px;">Review in Salesforce →</a>'
                    + '<h2 style="margin-top:40px;font-size:1.2rem;color:#14213d;border-bottom:2px solid #bfa243;padding-bottom:8px;letter-spacing:0.5px;">YOUR FP ONLY HOUSEHOLDS</h2>'
                    + '<table style="width:100%;border-collapse:collapse;margin-top:16px;">'
                    + '<thead>'
                    + '<tr style="background:#f3f4f6;color:#14213d;font-size:1rem;">'
                    + '<th style="padding:8px 12px;text-align:left;">HOUSEHOLD</th>'
                    + '<th style="padding:8px 12px;text-align:left;">SEGMENT</th>'
                    + '</tr>'
                    + '</thead>'
                    + '<tbody>';
                    for (Account acc : ownerAccountsToShow) {
                        String accUrl = baseUrl + '/' + acc.Id;
                        String segment = acc.get('Segmentation__c') != null ? String.valueOf(acc.get('Segmentation__c')) : '—';
                        emailBody += '<tr>'
                            + '<td style="padding:8px 12px;"><a href="' + accUrl + '" style="color:#14213d;text-decoration:underline;font-weight:600;">' + acc.Name + '</a><br><span style="font-size:0.95em;color:#888;">FP Only</span></td>'
                            + '<td style="padding:8px 12px;">' + segment + '</td>'
                            + '</tr>';
                    }
                    emailBody += '</tbody></table>';
                    if (hasMoreAccounts) {
                        emailBody += '<div style="color:#bfa243;font-size:1rem;margin-top:12px;">There might be additional records not shown in this email.</div>';
                    }
                    emailBody += '<div style="margin-top:32px;padding:16px;background:#f3f4f6;border-radius:6px;">'
                    + '<b style="color:#14213d;letter-spacing:1px;font-size:1em;">NEED HELP</b><br>Notify IT by completing the <a href="https://your.salesforce.feedback.form" style="color:#14213d;text-decoration:underline;">Salesforce Feedback Form</a>.'
                    + '</div>'
                    + '</div>' // end white card
                    + '<div style="background:#14213d;margin:0 auto 0 auto;border-radius:0 0 8px 8px;padding:24px 0 24px 0;margin-top:0;">'
                    + '<div style="max-width:600px;margin:0 auto;color:#fff;font-size:0.95em;line-height:1.5;">'
                    + 'ASCENTIS HOLDINGS · SEGMENTATION REMINDER · FY ' + year + ' WINDOW · 15 DEC ' + String.valueOf(Date.today().year()) + '<br>'
                    + 'You are receiving this because you own one or more FP Only households in Salesforce.'
                    + '</div></div>'
                    + '</div></div>';
                } else {
                    // FIRST NOTICE TEMPLATE
                    emailBody = ''
                    + '<div style="display:flex;justify-content:center;">'
                    + '<div style="min-width:900px;max-width:600px;font-family:\'Segoe UI\',Arial,sans-serif,serif,EmojiFont;background:#f8fafc;padding:0;margin:0;">'
                    + '<div style="background:#14213d;margin:0 auto 0 auto;border-radius:8px 8px 0 0;">'
                    + '<div style="height:56px;display:flex;align-items:center;justify-content:left;margin:0 auto;padding:0 0 0 0;">'
                    + '<span style="color:#fff;font-size:1.5rem;font-weight:700;letter-spacing:2px;margin-left:24px;">ASCENTIS</span>'
                    + '</div></div>'
                    + '<div style="margin:0 auto;background:#fff;border-radius:0 0 8px 8px;box-shadow:0 2px 8px #0001;padding:40px 32px 32px 32px;">'
                    + '<div style="color:#bfa243;font-size:13px;letter-spacing:1.5px;font-weight:600;margin-bottom:16px;">SEGMENTATION · FY ' + year + ' · NOTICE 01</div>'
                    + '<h1 style="font-size:2rem;color:#14213d;margin:0 0 16px 0;">The segmentation window is open.</h1>'
                    + '<div style="font-size:1.1rem;color:#14213d;margin-bottom:24px;">'
                    + 'Hi <b>' + advisorName + '</b> — your <b>' + fpOnlyCount + '</b> FP Only households lock to their ' + year + ' segment on <b>' + lockDate + '</b>. Review the list below and update only what has changed.'
                    + '</div>'
                    + '<div style="color:#3a4a5a;font-size:1rem;margin-bottom:24px;">'
                    + 'This notice covers FP Only clients only. Wealth client segments recalculate automatically on <b>' + lockDate + '</b>. Asset and Independent Advisor clients are not affected.'
                    + '<br><br>You must update a household’s segment when its agreement, Stated Net Worth, Stated Household Income, or Billed AUM has moved it to a different tier (AAA, A, B, C). If nothing has changed, no action is required — the current segment carries into ' + year + '.'
                    + '</div>'
                    + '<a href="' + reportUrl + '" style="display:inline-block;background:#bfa243;color:#14213d;font-weight:600;padding:12px 28px;border-radius:6px;text-decoration:none;margin-bottom:32px;margin-top:8px;">Review in Salesforce →</a>'
                    + '<h2 style="margin-top:40px;font-size:1.2rem;color:#14213d;border-bottom:2px solid #bfa243;padding-bottom:8px;letter-spacing:0.5px;">YOUR FP ONLY HOUSEHOLDS</h2>'
                    + '<table style="width:100%;border-collapse:collapse;margin-top:16px;">'
                    + '<thead>'
                    + '<tr style="background:#f3f4f6;color:#14213d;font-size:1rem;">'
                    + '<th style="padding:8px 12px;text-align:left;">HOUSEHOLD</th>'
                    + '<th style="padding:8px 12px;text-align:left;">SEGMENT</th>'
                    + '</tr>'
                    + '</thead>'
                    + '<tbody>';
                    for (Account acc : ownerAccountsToShow) {
                        String accUrl = baseUrl + '/' + acc.Id;
                        String segment = acc.get('Segmentation__c') != null ? String.valueOf(acc.get('Segmentation__c')) : '—';
                        emailBody += '<tr>'
                            + '<td style="padding:8px 12px;"><a href="' + accUrl + '" style="color:#14213d;text-decoration:underline;font-weight:600;">' + acc.Name + '</a><br><span style="font-size:0.95em;color:#888;">FP Only</span></td>'
                            + '<td style="padding:8px 12px;">' + segment + '</td>'
                            + '</tr>';
                    }
                    emailBody += '</tbody></table>';
                    if (hasMoreAccounts) {
                        emailBody += '<div style="color:#bfa243;font-size:1rem;margin-top:12px;">There might be additional records not shown in this email.</div>';
                    }
                    emailBody += '<div style="margin-top:32px;padding:16px;background:#f3f4f6;border-radius:6px;">'
                    + '<b style="color:#14213d;letter-spacing:1px;font-size:1em;">NEED HELP</b><br>Notify IT by completing the <a href="https://your.salesforce.feedback.form" style="color:#14213d;text-decoration:underline;">Salesforce Feedback Form</a>.'
                    + '</div>'
                    + '</div>' // end white card
                    + '<div style="background:#14213d;margin:0 auto 0 auto;border-radius:0 0 8px 8px;padding:24px 0 24px 0;margin-top:0;">'
                    + '<div style="max-width:600px;margin:0 auto;color:#fff;font-size:0.95em;line-height:1.5;">'
                    + 'ASCENTIS HOLDINGS · SEGMENTATION REMINDER · FY ' + year + ' WINDOW · 01 DEC ' + String.valueOf(Date.today().year()) + '<br>'
                    + 'You are receiving this because you own one or more FP Only households in Salesforce.'
                    + '</div></div>'
                    + '</div></div>';
                }

                mail.setHtmlBody(emailBody);
                if (orgWide != null) {
                    mail.setOrgWideEmailAddressId(orgWide.Id);
                }
                emailsToSend.add(mail);
            }
        }

        // Send email notifications
        if (!emailsToSend.isEmpty()) {
            try {
                System.debug('Emails sent for FP Only Accounts');
                if (bypassEmailSend) {
                    capturedEmails = emailsToSend;
                    return;
                }
                Messaging.sendEmail(emailsToSend);
            } catch (Exception ex) {
                ErrorLogService.logError(
                    'FPOnlyHouseholdReminderService',
                    'sendReminders',
                    'Failed to send FP Only reminder emails',
                    ex
                );
                throw ex;
            }
        }
    }
}