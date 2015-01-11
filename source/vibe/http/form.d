/**
	Convenience functions for working with web forms.

	Copyright: © 2012-2015 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Jan Krüger
*/
module vibe.http.form;

public import vibe.inet.webform;

import vibe.http.client : HTTPClientRequest; // for writeFormBody
import vibe.http.server;

import std.array;
import std.conv;
import std.range;
import std.string;


/**
	Encodes the given dictionary as URL encoded form data.
*/
void writeFormData(R)(R dst, in string[string] data)
	if (isOutputRange!(R, char))
{
	import vibe.textfilter.urlencode;

	bool first = true;
	foreach (k, v; data) {
		if (first) first = false;
		else dst.put("&");
		filterURLEncode(dst, k);
		dst.put("=");
		filterURLEncode(dst, v);
	}
}

///
unittest {
	import std.array;
	import vibe.core.log;
	import vibe.http.form;

	void test()
	{
		auto dst = appender!string();
		dst.writeFormData(["field1": "value1", "field2": "value2"]);
		logInfo("Form data: %s", dst.data);
	}
}


/**
	Writes a vibe.http.client.HTTPClientRequest body as URL encoded form data.
*/
void writeFormBody(HTTPClientRequest req, in string[string] form)
{
	import vibe.http.form;
	import vibe.stream.wrapper;

	StringLengthCountingRange len;
	writeFormData(&len, form);
	req.contentType = "application/x-www-form-urlencoded";
	req.contentLength = len.count;
	auto rng = StreamOutputRange(req.bodyWriter);
	writeFormData(&rng, form);
}

///
unittest {
	import vibe.core.log;
	import vibe.http.client;
	import vibe.http.form;
	import vibe.stream.operations;

	void sendForm()
	{
		requestHTTP("http://example.com/form",
			(scope req) {
				req.method = HTTPMethod.POST;
				req.writeFormBody(["field1": "value1", "field2": "value2"]);
			},
			(scope res) {
				logInfo("Response: %s", res.bodyReader.readAllUTF8());
			});
	}
}

/// private
struct StringLengthCountingRange {
	import std.utf;
	size_t count = 0;
	void put(string str) { count += str.length; }
	void put(dchar ch) { count += codeLength!char(ch); }
}
