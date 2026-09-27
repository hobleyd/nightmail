import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/latest_reply.dart';
import 'package:nightmail/domain/entities/email.dart';

void main() {
  group('latestReplyText — HTML', () {
    test('cuts at a Gmail quote', () {
      const html = '<div dir="ltr">Sounds good, let&#39;s meet.<br></div>'
          '<div class="gmail_quote"><div dir="ltr" class="gmail_attr">'
          'On Mon, 28 Sep 2026 at 09:00, Jane &lt;jane@example.com&gt; wrote:'
          '<br></div><blockquote class="gmail_quote">Original text'
          '</blockquote></div>';
      expect(latestReplyText(html, EmailBodyType.html),
          "Sounds good, let's meet.");
    });

    test('cuts at an Outlook appendonsend div', () {
      const html = '<html><body><div>Thanks, works for me.</div>'
          '<div id="appendonsend"></div><hr style="display:inline-block">'
          '<div id="divRplyFwdMsg"><b>From:</b> Jane<br><b>Sent:</b> Monday'
          '<br><b>Subject:</b> Re: plan</div><div>Original</div>'
          '</body></html>';
      expect(latestReplyText(html, EmailBodyType.html),
          'Thanks, works for me.');
    });

    test("cuts at Outlook desktop's From/Sent header block", () {
      const html = '<p class=MsoNormal>Yes please.</p>'
          '<div style="border:none;border-top:solid #E1E1E1 1.0pt">'
          '<p class=MsoNormal><b>From:</b> Jane &lt;jane@example.com&gt;<br>'
          '<b>Sent:</b> Monday, 28 September 2026 9:00 AM<br>'
          '<b>To:</b> Me<br><b>Subject:</b> Plan</p></div>'
          '<p class=MsoNormal>Original</p>';
      expect(latestReplyText(html, EmailBodyType.html), 'Yes please.');
    });

    test('cuts at a bare blockquote (Apple Mail, Thunderbird)', () {
      const html = '<div>Ok.</div><div><br></div>'
          '<div>On 28 Sep 2026, at 09:00, Jane wrote:</div>'
          '<blockquote type="cite"><div>Original</div></blockquote>';
      expect(latestReplyText(html, EmailBodyType.html), 'Ok.');
    });

    test('keeps the whole body when nothing is quoted', () {
      const html = '<div>Line one</div><div>Line two</div>';
      expect(latestReplyText(html, EmailBodyType.html), 'Line one\nLine two');
    });

    test('keeps the whole body when the cut would leave nothing', () {
      const html = '<blockquote>Only a quote</blockquote>';
      expect(latestReplyText(html, EmailBodyType.html), 'Only a quote');
    });

    test('drops style blocks and decodes entities', () {
      const html = '<html><head><style>p{color:red}</style></head>'
          '<body><p>Fish &amp; chips &nbsp;tonight</p></body></html>';
      expect(latestReplyText(html, EmailBodyType.html),
          'Fish & chips  tonight');
    });
  });

  group('latestReplyText — plain text', () {
    test('cuts at "On <date>, <who> wrote:"', () {
      const text = 'Sure.\n\nOn Mon, 28 Sep 2026 at 09:00, Jane '
          '<jane@example.com> wrote:\n> Original\n> text';
      expect(latestReplyText(text, EmailBodyType.text), 'Sure.');
    });

    test('cuts at a wrapped "wrote:" line', () {
      const text = 'Sure.\n\nOn Mon, 28 Sep 2026 at 09:00, Jane Somebody\n'
          '<jane@example.com> wrote:\n> Original';
      expect(latestReplyText(text, EmailBodyType.text), 'Sure.');
    });

    test('cuts at "-----Original Message-----"', () {
      const text = 'Noted.\n\n-----Original Message-----\nFrom: Jane\n'
          'Sent: Monday\nSubject: Plan\n\nOriginal';
      expect(latestReplyText(text, EmailBodyType.text), 'Noted.');
    });

    test('cuts at a From:/Sent: header block with no separator', () {
      const text = 'Noted.\n\nFrom: Jane <jane@example.com>\n'
          'Sent: Monday, 28 September 2026 9:00 AM\nTo: Me\nSubject: Plan\n'
          '\nOriginal';
      expect(latestReplyText(text, EmailBodyType.text), 'Noted.');
    });

    test('does not treat a passing "From:" as a header block', () {
      const text = 'From: my point of view this is fine.\n\nAnd so on.';
      expect(latestReplyText(text, EmailBodyType.text), text);
    });

    test('cuts at a trailing run of > lines', () {
      const text = 'Agreed.\n\n> Original\n> text\n';
      expect(latestReplyText(text, EmailBodyType.text), 'Agreed.');
    });

    test('keeps a > line that is not the tail of the message', () {
      const text = 'They said:\n> do it\nand I disagree.';
      expect(latestReplyText(text, EmailBodyType.text), text);
    });

    test('returns the whole body when the cut would leave nothing', () {
      const text = 'On Mon, Jane wrote:\n> Only a quote';
      expect(latestReplyText(text, EmailBodyType.text), text);
    });
  });

  group('meetingTitleForSubject', () {
    test('strips stacked reply and forward prefixes', () {
      expect(meetingTitleForSubject('Re: RE: Fwd: FW: Budget'), 'Budget');
      expect(meetingTitleForSubject('Re[2]: Budget'), 'Budget');
      expect(meetingTitleForSubject('  Budget  '), 'Budget');
    });

    test('keeps a subject that is only a prefix', () {
      expect(meetingTitleForSubject('Re:'), 'Re:');
    });

    test('does not eat a word that merely starts with a prefix', () {
      expect(meetingTitleForSubject('Reorganisation'), 'Reorganisation');
      expect(meetingTitleForSubject('Fwd budget'), 'Fwd budget');
    });
  });
}
