module ExercismAPI
  module Routes
    class Iterations < Core
      get '/iterations/:key/restore' do |key|
        halt *Xapi.get("v2", "exercises", "restore", key: key)
      end

      post '/user/fetch' do
        request.body.rewind
        data = request.body.read
        data = JSON.parse(data)
        user = User.where(key: data['key']).first
        # use the data['exercises'] (ids) to find which exercises are already
        # submitted
        ids = Array(data['problems'])
        existing_exercises = user.exercises.where(id: ids).pluck(:id)
        new_exercises = ids - existing_exercises
        new_exercises.each do |id|
          user.exercises.create(problem_id: id)
        end
      end

      post '/user/assignments' do
        request.body.rewind
        data = request.body.read
        if data.empty?
          halt 400, {error: "must send key and code as json"}.to_json
        end
        data = JSON.parse(data)
        user = User.where(key: data['key']).first
        begin
          LogEntry.create(user: user, key: data['key'], body: data.merge(user_agent: request.user_agent).to_json)
        rescue => e
          Bugsnag.notify(e)
          # ignore failures
        end
        unless user
          message = <<-MESSAGE
          unknown api key '#{data['key']}', please check your exercism.io account page and reconfigure
          MESSAGE
          halt 401, {error: message}.to_json
        end

        attempt = Attempt.new(user, data['code'], data['path'])

        unless attempt.valid?
          error = "unknown problem (track: #{attempt.file.track}, slug: #{attempt.file.slug}, path: #{data['path']})"
          halt 400, {error: error}.to_json
        end

        if attempt.duplicate?
          halt 400, {error: "duplicate of previous iteration"}.to_json
        end

        attempt.save
        Notify.everyone(attempt.submission.reload, 'code', user)
        # if we don't have a 'fetched' event, we want to hack one in.
        LifecycleEvent.track('fetched', user.id)
        LifecycleEvent.track('submitted', user.id)
        status 201
        pg :attempt, locals: {submission: attempt.submission, domain: request.url.gsub(/#{request.path}$/, "")}
      end

      delete '/user/assignments' do
        require_key
        begin
          Unsubmit.new(current_user).unsubmit
        rescue Unsubmit::NothingToUnsubmit
          halt 404, {error: "Nothing to unsubmit."}.to_json
        rescue Unsubmit::SubmissionHasNits
          halt 403, {error: "The submission has nitpicks, so can't be deleted."}.to_json
        rescue Unsubmit::SubmissionDone
          halt 403, {error: "The submission has been already completed, so can't be deleted."}.to_json
        rescue Unsubmit::SubmissionTooOld
          halt 403, {error: "The submission is too old to be deleted."}.to_json
        end
        status 204
      end

      get '/iterations/latest' do
        require_key

        submissions = current_user.exercises.order(:language, :slug).map {|exercise|
          exercise.submissions.last
        }.compact
        pg :iterations, locals: {submissions: submissions}
      end
    end
  end
end
