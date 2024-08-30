﻿using GennyMaui.Models;
using Microsoft.ML.OnnxRuntimeGenAI;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using CommunityToolkit.Maui.Storage;
using System.Text.Json;
using CommunityToolkit.Mvvm.Messaging.Messages;
using CommunityToolkit.Mvvm.Messaging;


namespace GennyMaui.ViewModels
{
    public partial class LoadableModel : ObservableObject
    {
        [ObservableProperty]
        private Model? _model;

        [ObservableProperty]
        private Tokenizer? _tokenizer;

        [ObservableProperty]
        private ConfigurationModel? _configuration;

        [ObservableProperty]
        private string _modelPath;

        [ObservableProperty]
        private bool _isModelLoaded;

        [ObservableProperty]
        private bool _isModelLoading;

        [ObservableProperty]
        private bool _isLocalModelSelected;

        [ObservableProperty]
        private string _localModelStatusString = string.Empty;

        public List<HuggingFaceModel> RemoteModels { get; } =
        [
            new()
            {
                RepoId = "microsoft/Phi-3-mini-4k-instruct-onnx",
                Include = "cpu_and_mobile/cpu-int4-rtn-block-32-acc-level-4/*",
                Subpath = "cpu_and_mobile/cpu-int4-rtn-block-32-acc-level-4"
            },
            new ()
            {
                RepoId = "microsoft/mistral-7b-instruct-v0.2-ONNX",
                Include = "onnx/cpu_and_mobile/mistral-7b-instruct-v0.2-cpu-int4-rtn-block-32-acc-level-4/*",
                Subpath = "onnx/cpu_and_mobile/mistral-7b-instruct-v0.2-cpu-int4-rtn-block-32-acc-level-4"
            }
        ];

        private async Task<bool> OpenModelAsync()
        {
#if ANDROID
            return false;
#else
            var result = await FolderPicker.Default.PickAsync();

            if (result.IsSuccessful)
            {
                ModelPath = result.Folder.Path;
                return true;
            }
            else
            {
                await Application.Current.MainPage.DisplayAlert("Folder Open Error", result.Exception.Message, "OK");
                return false;
            }
#endif
        }

        [RelayCommand(CanExecute = "CanExecuteLoadModel")]
        private async Task LoadModelAsync()
        {
            await UnloadModelAsync();
            try
            {
                var currentModelPath = CurrentSelectedModelPath();
                IsModelLoading = true;
                Configuration = await LoadConfigAsync(currentModelPath);

                WeakReferenceMessenger.Default.Send(new PropertyChangedMessage<ConfigurationModel>(this, nameof(Configuration), null, Configuration));
                WeakReferenceMessenger.Default.Send(new PropertyChangedMessage<SearchOptionsModel>(this, nameof(SearchOptionsModel), null, Configuration.SearchOptions));

                await Task.Run(() =>
                {
                    Model = new Model(currentModelPath);
                    Tokenizer = new Tokenizer(Model);
                });
                IsModelLoaded = true;

                RefreshLocalModelStatus();
                RefreshRemoteModelStatus();

                WeakReferenceMessenger.Default.Send(new PropertyChangedMessage<Model>(this, nameof(Model), null, Model));
                WeakReferenceMessenger.Default.Send(new PropertyChangedMessage<Tokenizer>(this, nameof(Tokenizer), null, Tokenizer));
            }
            catch (Exception ex)
            {
                await Application.Current.MainPage.DisplayAlert("Model Load Error", ex.Message, "OK");
            }
            finally
            {
                IsModelLoading = false;
            }
        }

        private bool CanExecuteLoadModel()
        {
            return !string.IsNullOrWhiteSpace(CurrentSelectedModelPath());
        }

        private Task UnloadModelAsync()
        {
            Model?.Dispose();
            Tokenizer?.Dispose();
            IsModelLoaded = false;
            return Task.CompletedTask;
        }

        private static async Task<ConfigurationModel> LoadConfigAsync(string modelPath)
        {
            var configPath = Path.Combine(modelPath, "genai_config.json");
            var configJson = await File.ReadAllTextAsync(configPath);
            return JsonSerializer.Deserialize<ConfigurationModel>(configJson);
        }

        private async Task DownloadHuggingFaceModel(HuggingFaceModel hfModel)
        {
            try
            {
                hfModel.IsDownloading = true;
                await HuggingfaceHub.HFDownloader.DownloadSnapshotAsync(
                    hfModel.RepoId,
                    allowPatterns: [hfModel.Include],
                    localDir: hfModel.DownloadPath
                    );
            }
            finally
            {
                hfModel.IsDownloading = false;
                RefreshRemoteModelStatus();
            }
        }

        private string CurrentSelectedModelPath()
        {
            if (IsLocalModelSelected)
            {
                return ModelPath;
            }

            foreach (var item in RemoteModels)
            {
                if (item.IsChecked && item.Exists)
                {
                    return item.ModelPath;
                }
            }

            return string.Empty;
        }

        internal void ToggleLocalModel(bool ischecked)
        {
            if (!ischecked)
            {
                if (IsModelLoaded)
                {
                    UnloadModelAsync().ContinueWith(t =>
                    {
                        if (t.IsCompleted)
                        {
                            App.Current.Dispatcher.Dispatch(() =>
                            {
                                RefreshLocalModelStatus();
                            });
                        }
                    });
                }
                return;
            }

            foreach (var item in RemoteModels)
            {
                item.IsChecked = false;
            }

            if (Path.Exists(ModelPath))
            {
                RefreshLocalModelStatus();
                return;
            }

            OpenModelAsync().ContinueWith(t =>
            {
                if (t.Result)
                {
                    App.Current.Dispatcher.Dispatch(() =>
                    {
                        RefreshLocalModelStatus();
                    });
                }
                else
                {
                    IsLocalModelSelected = false;
                }
            });
        }

        internal void ToggleHuggingfaceModel(HuggingFaceModel hfModel, bool ischecked)
        {
            if (!ischecked)
            {
                if (IsModelLoaded)
                {
                    UnloadModelAsync().ContinueWith(t =>
                    {
                        if (t.IsCompleted)
                        {
                            App.Current.Dispatcher.Dispatch(() =>
                            {
                                RefreshRemoteModelStatus();
                            });
                        }
                    });
                }
                return;
            }

            IsLocalModelSelected = false;
            foreach (var item in RemoteModels)
            {
                if (item.RepoId != hfModel.RepoId)
                {
                    item.IsChecked = false;
                }
            }

            if (hfModel.Exists)
            {
                RefreshRemoteModelStatus();
                return;
            }
            else
            {
                DownloadHuggingFaceModel(hfModel);
            }
        }

        internal void RefreshLocalModelStatus()
        {
            if (!IsModelLoaded && !Path.Exists(ModelPath))
            {
                LocalModelStatusString = "(❌Not available)";
            }

            if (Path.Exists(ModelPath))
            {
                LocalModelStatusString = "(⚡Ready to load)";
            }

            if (IsModelLoaded && IsLocalModelSelected)
            {
                LocalModelStatusString = "(✅Loaded)";
            }

            LoadModelCommand.NotifyCanExecuteChanged();
        }

        internal void RefreshRemoteModelStatus()
        {
            foreach (var item in RemoteModels)
            {
                if (IsModelLoaded && CurrentSelectedModelPath() == item.ModelPath)
                {
                    item.StatusString = "(✅Loaded)";
                    continue;
                }

                if (item.Exists)
                {
                    item.StatusString = "(⚡Ready to load)";
                }
                else
                {
                    item.StatusString = "(🔽Downloadable)";
                }
            }

            LoadModelCommand.NotifyCanExecuteChanged();
        }
    }
}
