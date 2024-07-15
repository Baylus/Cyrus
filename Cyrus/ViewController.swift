//
//  ViewController.swift
//  Cyrus
//
//  Created by Josue Espinosa on 12/23/17.
//  Copyright © 2017 Josue Espinosa. All rights reserved.
//

import UIKit

class ViewController: UIViewController {

    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var voiceQueryTextView: UITextView!
    @IBOutlet weak var sqliteQueryTextView: UITextView!
    @IBOutlet weak var resultsTextView: UITextView!
    @IBOutlet weak var recordButton: UIButton!

    private var isRecording = false
    private var isAuthorized = false

    private var databaseTableNames = [String]()

    private var latestVoiceQuery = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        DatabaseHelper.prepareDatabase()
        databaseTableNames = DatabaseHelper.getTableNamesFromDatabase().map { $0.lowercased() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isAuthorized {
            SpeechHelper.requestAuthorization(completion: { authorizationStatus in
                self.isAuthorized = (authorizationStatus == .authorized)
                self.recordButton.isEnabled = self.isAuthorized
                if !self.isAuthorized {
                    let alert = UIAlertController(title: "Error",
                                                  message: "Please grant Cyrus mic & speech recognition authorization.",
                                                  preferredStyle: UIAlertControllerStyle.alert)
                    alert.addAction(UIAlertAction(title: "Click", style: UIAlertActionStyle.default, handler: nil))
                    self.present(alert, animated: true, completion: nil)
                }
            })
        }
    }

    func updateVoiceTranscription(transcription: String) {
        latestVoiceQuery = transcription
//        latestVoiceQuery = "name and year of movies"    // Added this in to automate input during tests
//        latestVoiceQuery = "Show me title and year from the movies table"    // Added this in to automate input during tests
//        latestVoiceQuery = "Show me count of title and average year from the movies table"    // Added this in to automate input during tests
//        latestVoiceQuery = "average metascore of movies"    // Added this in to automate input during tests
        latestVoiceQuery = "average metascore of movies group by year"    // Added this in to automate input during tests
//        latestVoiceQuery = "directors and mean metascore of movies group by Director"    // Added this in to automate input during tests
//        latestVoiceQuery = "years and average rating movies group by year"    // Added this in to automate input during tests
//        latestVoiceQuery = "movies with director M. Night Shyamalan"    // Added this in to automate input during tests
        voiceQueryTextView.text = latestVoiceQuery
    }

//    Keywords to different schemes
//    matching the best
//    Chapter 15, section 15.3
    // inference queries, (give answer to question without a response) "I want a chinese resteraunt in moscow" "There is one in lewiston,
//    table saying "indian food is similar to chionese", or whatever
    //    aggregate queries: Things like average, sum,
    func convertVoiceQueryToSql() -> String {
        /*
         
         
         Details:
            If your input string mentions the name of a table before it mentions any column names,
                then your output will always start with "SELECT * FROM TableName", it may be followed by
                other things, but it will always start by selecting the whole table.
         
         Aggregating over the distance of either a single grouo or over every group in the table.
         
         Do aggregate queries first, in a single table
         
         then focus on join queries for multiple tables to make a single table
         
         Approximate queries:
         everytime that you fail, try and look at the similarity table that you use to try compare one query to another.
         you would join the tables together to create an extended row.
         peripheral view setup
        */
        var words = latestVoiceQuery.components(separatedBy: " ")
        let queryWords = words
        var wordSpliceIndices = [Int]()
        // Extract which tables should be used from the voice query
        let tablesUsedInQuery = getKeywordsUsedInVoiceQuery(keywords: databaseTableNames,
                                                                tokenizedVoiceQuery: words,
                                                                delimiter: "_",
                                                                startIndex: 0,
                                                                endIndex: Swift.max(0, (words.count - 1)),
                                                                startingSpliceIndices: &wordSpliceIndices)
        // since we can't mutate the array during enumeration in getKeywordsUsedInVoiceQuery,
        // merge compound table names after finding them
        spliceWordsAtIndices(words: &words, delimiter: "_", indices: &wordSpliceIndices)

        // TODO: support more than 1 table for queries
        let mainTable = tablesUsedInQuery[0]
        let mainTableIndex = words.index(of: mainTable)!

        let mainTableColumns = DatabaseHelper.getAllColumnNamesFromTable(tableName: mainTable).map { $0.lowercased() }
        
        // columnsBeforeTable means the number of times a word found could be related to a column before the table name was referenced
        let columnsBeforeTable = getKeywordsUsedInVoiceQuery(keywords: mainTableColumns,
                                                                     tokenizedVoiceQuery: words,
                                                                     delimiter: "",
                                                                     startIndex: 0,
                                                                     endIndex: Swift.max(0, (mainTableIndex - 1)),
                                                                     startingSpliceIndices: &wordSpliceIndices)
        // merge compound column names before table name
        spliceWordsAtIndices(words: &words, delimiter: "", indices: &wordSpliceIndices)

        // Same as columnsBeforeTable, except opposite.
        let columnsAfterTable = getKeywordsUsedInVoiceQuery(keywords: mainTableColumns,
                                                                    tokenizedVoiceQuery: words,
                                                                    delimiter: "",
                                                                    startIndex: Swift.min(mainTableIndex + 1, (words.count - 1)),
                                                                    endIndex: words.count - 1,
                                                                    startingSpliceIndices: &wordSpliceIndices)
        // merge compound column names after table name
        spliceWordsAtIndices(words: &words, delimiter: "", indices: &wordSpliceIndices)

        var columnsValuesAndTypesForWhereClause = [(String, String, String)]()

        if columnsAfterTable.count > 0 {
            // we saved the column names before the table name and already know the table name
            // keep everything after the table name for performance in future loops
            words = Array(words.suffix((words.count - 1) - mainTableIndex))
            let prunedVoiceQuery = words.joined(separator: " ")
            // we don't need parts of speech until assigning where clause stuff for number vs proper noun
            var tokenizedQueryAndPartsOfSpeech = NaturalLanguageParser.partsOfSpeech(text: prunedVoiceQuery)
            // .joinNames from our tagger to simplify things like ["Jimi", "Hendrix"] -> ["Jimi Hendrix"]
            words = tokenizedQueryAndPartsOfSpeech.map { $0.0.lowercased() }

            columnsValuesAndTypesForWhereClause = findValuesForWhereColumns(columns: columnsAfterTable,
                                                                       words: &words,
                                                                       tokenizedQueryAndPartsOfSpeech: &tokenizedQueryAndPartsOfSpeech)

        }

        // if no select columns specified, select all
        // Because this uses columnsBeforeTable
        let selectColumns = (columnsBeforeTable.count > 0) ? columnsBeforeTable.joined(separator: ", ") : "*"
        var selectColumnsTest = ""
        var beforeTable = columnsBeforeTable
        if (columnsBeforeTable.count > 0) {
            // Handle aggregate query cases.
            // AVG
            beforeTable = getAggregateClauseFromKeywords(columns: beforeTable, tokenizedVoiceQuery: queryWords,
                                                         beforeWords: ["average","mean"],
                                                         afterWords: ["average"],
                                                         aggregateFunction: "AVG",
                                                         startIndex: 0, endIndex: Swift.max(0, (mainTableIndex - 1)))
            // COUNT
            beforeTable = getAggregateClauseFromKeywords(columns: beforeTable, tokenizedVoiceQuery: queryWords,
                                                         beforeWords: ["count"],
                                                         afterWords: ["count"],
                                                         aggregateFunction: "COUNT",
                                                         startIndex: 0, endIndex: Swift.max(0, (mainTableIndex - 1)))
            // MAX
            beforeTable = getAggregateClauseFromKeywords(columns: beforeTable, tokenizedVoiceQuery: queryWords,
                                                         beforeWords: ["max", "maximum", "largest", "biggest"],
                                                         afterWords: ["max", "maximum"],
                                                         aggregateFunction: "MAX",
                                                         startIndex: 0, endIndex: Swift.max(0, (mainTableIndex - 1)))
            // MIN
            beforeTable = getAggregateClauseFromKeywords(columns: beforeTable, tokenizedVoiceQuery: queryWords,
                                                         beforeWords: ["min", "minimum", "smallest"],
                                                         afterWords: ["min", "minimum"],
                                                         aggregateFunction: "MIN",
                                                         startIndex: 0, endIndex: Swift.max(0, (mainTableIndex - 1)))
            // SUM
            beforeTable = getAggregateClauseFromKeywords(columns: beforeTable, tokenizedVoiceQuery: queryWords,
                                                         beforeWords: ["sum", "summation", "addition", "total"],
                                                         afterWords: ["sum", "summation", "addition", "total"],
                                                         aggregateFunction: "SUM",
                                                         startIndex: 0, endIndex: Swift.max(0, (mainTableIndex - 1)))
            selectColumnsTest = beforeTable.joined(separator: ", ")
        }
        else {
            // No columns before table
            selectColumnsTest = "*"
        }
        
//        var sql = "SELECT " + selectColumns + " "
        var sql = "SELECT " + selectColumnsTest + " "
        sql += "FROM " + mainTable
        if columnsValuesAndTypesForWhereClause.count > 0 {
            sql += " WHERE "
            for i in 0...(columnsValuesAndTypesForWhereClause.count - 1) {
                let item = columnsValuesAndTypesForWhereClause[i]
                if item.2 == NSLinguisticTag.number.rawValue {
                    sql += item.0 + " = " + item.1 + " AND "
                } else {
                    sql += item.0 + " LIKE " + "'" + item.1 + "'" + " AND " + "'"
                }

                if i == (columnsValuesAndTypesForWhereClause.count - 1) {
                    sql = String(sql.prefix((sql.count - 1) - " AND ".count))
                }
            }
        }
        // Group by.
        if (words.contains("group")) {
            // needs a group.
            for i in 0...(words.count - 1) {
                // iterate over words
                if (words[i] == "group" && words[i + 1] == "by") {
                    // makeshift add group by.
                    sql += " GROUP BY " + words[i + 2]
                }
            }
        }

        return sql
    }

    func findValuesForWhereColumns(columns: [String],
                                   words: inout [String],
                                   tokenizedQueryAndPartsOfSpeech: inout [(String, String)]) -> [(String, String, String)] {
        var columnsAndValuesForWhereClause = [(String, String, String)]()
        let acceptableWhereClauseTagTypes: [NSLinguisticTag] = [.number, .placeName, .personalName, .organizationName]
        let acceptableWhereClauseTags = acceptableWhereClauseTagTypes.map { $0.rawValue }
        var incrementStepper = 1
        for column in columns {
            var foundOrExhausted = false
            while !foundOrExhausted {
                var columnIndex = words.index(of: column)!
                var searchIndex = columnIndex
                var checkedAtLeastOneSide = false
                // check left hand side first, since we're checking the left most where column,
                // it's impossible to steal from the adjacent right column from the left
                // because there's no extra where column to the left
                if (searchIndex - incrementStepper) >= 0 {
                    checkedAtLeastOneSide = true
                    // main table name was at hypothetical index -1, we truncated the select clauses and the table name, verify we're not going out of bounds
                    searchIndex -= incrementStepper
                    let partOfSpeech = tokenizedQueryAndPartsOfSpeech[searchIndex].1
                    if acceptableWhereClauseTags.contains(partOfSpeech) {
                        columnsAndValuesForWhereClause.append((column, words[searchIndex], partOfSpeech))
                        words.remove(at: searchIndex)
                        columnIndex = words.index(of: column)!
                        words.remove(at: columnIndex)
                        tokenizedQueryAndPartsOfSpeech.remove(at: searchIndex)
                        tokenizedQueryAndPartsOfSpeech.remove(at: columnIndex)
                        foundOrExhausted = true
                        continue
                    }
                }
                searchIndex = columnIndex
                if (searchIndex + incrementStepper) <= tokenizedQueryAndPartsOfSpeech.count - 1 {
                    checkedAtLeastOneSide = true
                    searchIndex += incrementStepper
                    let partOfSpeech = tokenizedQueryAndPartsOfSpeech[searchIndex].1
                    if acceptableWhereClauseTags.contains(partOfSpeech) {
                        columnsAndValuesForWhereClause.append((column, words[searchIndex], partOfSpeech))
                        words.remove(at: searchIndex)
                        columnIndex = words.index(of: column)!
                        words.remove(at: columnIndex)
                        tokenizedQueryAndPartsOfSpeech.remove(at: searchIndex)
                        tokenizedQueryAndPartsOfSpeech.remove(at: columnIndex)
                        foundOrExhausted = true
                        continue
                    }
                }
                if !checkedAtLeastOneSide {
                    foundOrExhausted = true
                    continue
                }
                incrementStepper += 1
            }
        }
        return columnsAndValuesForWhereClause
    }

    // try calling this when the situation arises, then callback with the starting index as the passed index + 1
    func spliceWordsAtIndex(words: inout [String], index: Int) {
        words[index] = words[index] + "_" + words[index + 1]
        words.remove(at: index + 1)
    }

    func spliceWordsAtIndices(words: inout [String], delimiter: String, indices: inout [Int]) {
        if indices.count > 0 {
            for i in 0...(indices.count - 1) {
                let index = indices[i]
                words[index] = words[index] + delimiter + words[index + 1]
                words.remove(at: index + 1)
            }
        }
    }
    
    // (columns: columnsBeforeTable,
    //    tokenizedVoiceQuery: words,
    //    startIndex: 0,
    //    endIndex: Swift.max(0, (words.count - 1)),
    //    startingSpliceIndices: &wordSpliceIndices)
    func getAggregateClauseFromKeywords(columns: [String],
                                     tokenizedVoiceQuery: [String],
                                     beforeWords: [String],
                                     afterWords: [String],
                                     aggregateFunction: String,
                                     startIndex: Int,
                                     endIndex: Int) -> [String] {
        /*
         Takes a list of strings as input and compares them with keywords to find similarities and
         returns a resulting array of keywords that have similar strings in the list of input strings
         
         Details:
            Most important thing about this is that for each aggregate query, none of the beforeWords or afterWords
            can be reused, because this will lead to multiple select statements being made for the one intended select statement
         
         Uses:
         columns: string list, names of columns found before table name
         tokenizedVoiceQuery: string list, array of words in query
         beforeWords: string list, words that are found before column names to signify aggregate query
         afterWords: string list, same as beforeWords, except after.
         aggregateFunction: string, aggregate function to use, e.g. "AVG", "MAX", "COUNT", etc.
         startIndex: int, where to start in query string
         endIndex: int, where to end in query string
         
         */
        var aggregatedSelectStatements = [String]()
        var pWord = ""  // Word matching last word before word
        var cWord = ""  // Word matching one of the columns.
        var cols = columns
//        var checkNextWordForCompoundKeyword = false
        for i in startIndex...endIndex {
            let word = tokenizedVoiceQuery[i].lowercased()
            if (word == "and") {
                // "and" means that we cannot be matching a column name with an aggregate query afterWord
                // e.g. "title and count actors in movies", the "count" cannot be referencing the title, since
                // the and means that we want to "SELECT title, COUNT(actors) FROM movies"
                cWord = ""
            }
            else if (cols.contains(word)) {
                // found a column
                if (pWord != "") {
                    // a preword existed
                    pWord = "" // reset pre word
                    cWord = ""
                    aggregatedSelectStatements.append(aggregateFunction + "(" + word + ")")
                    cols = cols.filter{$0 != word}
//                    cols.remove(word)    // Remove the word added, so as not to check it again
                }
                else {
                    // word didn't exist
                    cWord = word
                }
            }
            else if (beforeWords.contains(word)) {
                // Found a before word.
                pWord = word
            }
            else if (afterWords.contains(word)) {
                // found after word
                if (cWord != "") {
                    // Matching word exists.
                    pWord = "" // reset pre word
                    aggregatedSelectStatements.append(aggregateFunction + "(" + cWord + ")")
                    cWord = ""
                }
            }
        }
        // Add in all the values that were unchanged.
        for column in cols {
            aggregatedSelectStatements.append(column)
        }
        
        return aggregatedSelectStatements
    }
    // (keywords: databaseTableNames,
//    tokenizedVoiceQuery: words,
//    delimiter: "_",
//    startIndex: 0,
//    endIndex: Swift.max(0, (words.count - 1)),
//    startingSpliceIndices: &wordSpliceIndices)
    func getKeywordsUsedInVoiceQuery(keywords: [String],
                                     tokenizedVoiceQuery: [String],
                                     delimiter: String,
                                     startIndex: Int,
                                     endIndex: Int,
                                     startingSpliceIndices: inout [Int]) -> [String] {
        /*
         Takes a list of strings as input and compares them with keywords to find similarities and
         returns a resulting array of keywords that have similar strings in the list of input strings
        */
        var keyWordsUsedInQuery = [String]()
        for keyword in keywords {
            var lastWord = ""
            var checkNextWordForCompoundKeyword = false
            for i in startIndex...endIndex {
                let word = tokenizedVoiceQuery[i].lowercased()
                if checkNextWordForCompoundKeyword {
                    // TODO: work with any delimiter instead of hardcoding for "_"
                    // TODO: work for any compound length instead of hardcoding for 2 words
                    let compoundKeyword = lastWord + delimiter + word
                    if compoundKeyword == keyword {
                        startingSpliceIndices.append(i - 1)
                        keyWordsUsedInQuery.append(compoundKeyword)
                    }
                    lastWord = ""
                    checkNextWordForCompoundKeyword = false
                } else if keyword.contains(word) && keyword != word {
                    checkNextWordForCompoundKeyword = true
                    lastWord = word
                } else if Utilities.levenshteinDistance(firstWord: word, secondWord: keyword) <= 1 {
                    // account for single character differences for plural/singular keyword mistakes by the user
                    keyWordsUsedInQuery.append(keyword)
                    // TODO: replace the close word to the keyword in the tokenizedVoiceQuery array
                }
            }
        }
        return keyWordsUsedInQuery
    }

    @IBAction func recordButtonTapped(_ sender: Any) {
        if isRecording {
            SpeechHelper.stopRecordingSpeech()
            let sql = convertVoiceQueryToSql()
            sqliteQueryTextView.text = sql
            let results = DatabaseHelper.executeSql(sql: sql).joined(separator: " ")
            resultsTextView.text = results
            SpeechHelper.speak(transcript: results)
            statusLabel.text = "Cyrus (ready to listen)"
            recordButton.setTitle("Record", for: .normal)
        } else {
            SpeechHelper.stopSpeaking()
            SpeechHelper.recordSpeech(newTranscriptionAvailable: updateVoiceTranscription)
            statusLabel.text = "Cyrus (listening...)"
            voiceQueryTextView.text = ""
            recordButton.setTitle("Stop Recording", for: .normal)
        }

        isRecording = !isRecording
    }

}
